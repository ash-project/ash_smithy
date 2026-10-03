defmodule AshSmithy.Type do
  @moduledoc """
  Maps the types of an `Ash.Info.Manifest` to Smithy type descriptors.

  A descriptor is an intermediate representation used both to emit Smithy shapes and to
  encode/decode values on the wire, so that the model and the server can never disagree.

  Descriptors:

    * `{:simple, smithy_type, traits}` - a prelude shape (`"String"`, `"Long"`, ...) with member traits
    * `{:enum, name, values}` - a string enum shape. `values` is a list of `{member_name, value}`
    * `{:list, name, member_descriptor, sparse?}`
    * `{:map, name, key_descriptor, value_descriptor, sparse?}`
    * `{:int_enum, name, values}` - an integer enum. `values` is a list of `{member_name, value}`
    * `{:structure, name, members}` - members are `AshSmithy.Type.Member` structs
    * `{:union, name, members}` - members are `AshSmithy.Type.Member` structs
    * `{:resource, resource}` - a reference to a resource's structure, expanded lazily with
      `resource_structure/1` so that recursive resources are supported
    * `{:lazy, module, function, args}` - a descriptor computed lazily, for recursive shapes

  Custom Ash types can control their mapping by defining `smithy_type/1`, which receives the
  constraints and must return a descriptor.
  """

  defmodule Member do
    @moduledoc "A member of a structure or union descriptor."
    defstruct [:name, :member, :descriptor, :description, required?: false, traits: %{}]

    @type t :: %__MODULE__{
            name: atom,
            member: String.t(),
            descriptor: AshSmithy.Type.descriptor(),
            description: String.t() | nil,
            required?: boolean,
            traits: map
          }
  end

  @type descriptor ::
          {:simple, String.t(), map}
          | {:enum, String.t(), [{String.t(), String.t()}]}
          | {:list, String.t(), descriptor, boolean}
          | {:map, String.t(), descriptor, descriptor, boolean}
          | {:int_enum, String.t(), [{String.t(), integer}]}
          | {:structure, String.t(), [Member.t()]}
          | {:union, String.t(), [Member.t()]}
          | {:resource, Ash.Resource.t()}
          | {:lazy, module, atom, list}

  @timestamp_traits %{"smithy.api#timestampFormat" => "date-time"}

  @doc """
  Returns the descriptor for a type from an `Ash.Info.Manifest`.

  `name` is used to name any shapes that must be generated for the type, e.g. an enum for an
  atom attribute with `one_of` constraints. `manifest` is used to resolve named types.
  """
  @spec describe(Ash.Info.Manifest.Type.t(), String.t(), AshSmithy.Manifest.t()) :: descriptor
  def describe(%Ash.Info.Manifest.Type{} = type, name, manifest) do
    constraints = type.constraints || []

    cond do
      custom_type?(type.module) ->
        type.module.smithy_type(constraints)

      type.kind == :type_ref ->
        describe_named(AshSmithy.Manifest.resolve(manifest, type), manifest)

      true ->
        describe_kind(type, constraints, name, manifest)
    end
  end

  defp custom_type?(module) do
    is_atom(module) and not is_nil(module) and Code.ensure_loaded?(module) and
      function_exported?(module, :smithy_type, 1)
  end

  # Named types (enums, new types and embedded resources) are named after their module
  defp describe_named(%{kind: :embedded_resource, module: module}, _manifest),
    do: {:resource, module}

  defp describe_named(type, manifest), do: describe(type, type_name(type.module), manifest)

  defp describe_kind(type, constraints, name, manifest) do
    case type.kind do
      :array ->
        {:list, name <> "List", describe(type.item_type, name <> "Item", manifest),
         constraints[:nil_items?] == true}

      kind when kind in [:string, :ci_string] ->
        {:simple, "String", string_traits(constraints)}

      :enum ->
        enum(
          if(type.module == Ash.Type.Atom, do: name, else: type_name(type.module)),
          type.values
        )

      kind when kind in [:atom, :uuid, :date, :time, :time_usec, :duration] ->
        {:simple, "String", %{}}

      :integer ->
        {:simple, "Long", range_traits(constraints)}

      :float ->
        {:simple, "Double", range_traits(constraints)}

      :decimal ->
        {:simple, "BigDecimal", range_traits(constraints)}

      :boolean ->
        {:simple, "Boolean", %{}}

      :binary ->
        {:simple, "Blob", %{}}

      kind when kind in [:datetime, :utc_datetime, :utc_datetime_usec, :naive_datetime] ->
        {:simple, "Timestamp", @timestamp_traits}

      kind when kind in [:resource, :embedded_resource] ->
        {:resource, type.resource_module || type.instance_of || type.module}

      kind when kind in [:map, :struct, :keyword] ->
        cond do
          type.fields ->
            {:structure, name, fields_members(type.fields, name, manifest)}

          # Keyword lists can't be round tripped through JSON objects without fields
          kind == :keyword ->
            {:simple, "Document", %{}}

          # Ash only accepts objects for maps, so this is more precise than a bare document
          true ->
            {:map, name, {:simple, "String", %{}}, {:simple, "Document", %{}}, false}
        end

      :union ->
        {:union, name,
         Enum.map(type.members || [], fn member ->
           %Member{
             name: member.name,
             member: AshSmithy.Naming.member_name(member.name),
             descriptor:
               describe(member.type, name <> AshSmithy.Naming.shape_name(member.name), manifest),
             description: member[:description]
           }
         end)}

      _ ->
        {:simple, "Document", %{}}
    end
  end

  @doc """
  Smithy resource identifiers must target a string or enum shape, so any other type is modeled
  as a string.
  """
  @spec identifier_descriptor(descriptor) :: descriptor
  def identifier_descriptor({:simple, "String", _} = descriptor), do: descriptor
  def identifier_descriptor({:enum, _, _} = descriptor), do: descriptor
  def identifier_descriptor(_), do: {:simple, "String", %{}}

  @doc "The descriptor for a resource's structure shape, built from its manifest."
  @spec resource_structure(Ash.Resource.t()) :: descriptor
  def resource_structure(resource) do
    manifest = AshSmithy.Manifest.for_resource(resource)
    definition = manifest.resource
    name = resource_name(resource)

    identifiers =
      if AshSmithy.Resource.Info.smithy_resource?(resource) do
        AshSmithy.Resource.Info.identifiers(resource)
      else
        []
      end

    members =
      resource
      |> resource_fields(definition)
      |> Enum.map(fn field_name ->
        field = Ash.Info.Manifest.Resource.get_field(definition, field_name)

        descriptor =
          describe(field.type, name <> AshSmithy.Naming.shape_name(field.name), manifest)

        if field.name in identifiers do
          %Member{
            name: field.name,
            member: resource_member_name(resource, field.name),
            descriptor: identifier_descriptor(descriptor),
            description: field.description,
            required?: true,
            traits: %{
              "smithy.api#resourceIdentifier" =>
                AshSmithy.Resource.Info.identifier_name(resource, field.name)
            }
          }
        else
          %Member{
            name: field.name,
            member: resource_member_name(resource, field.name),
            descriptor: descriptor,
            description: field.description,
            required?: field.allow_nil? == false,
            # Calculations and aggregates are derived, so they are not properties of the resource
            traits:
              if field.kind == :attribute do
                %{}
              else
                %{"smithy.api#notProperty" => %{}}
              end
          }
        end
      end)

    {:structure, name, members ++ relationship_members(resource, definition)}
  end

  # Exposed relationships are optional members, only present when included.
  defp relationship_members(resource, definition) do
    if AshSmithy.Resource.Info.smithy_resource?(resource) do
      resource
      |> AshSmithy.Resource.Info.smithy_relationships!()
      |> Enum.map(fn relationship_name ->
        relationship = Ash.Info.Manifest.Resource.get_relationship(definition, relationship_name)
        destination = {:resource, relationship.destination}

        descriptor =
          if relationship.cardinality == :many do
            {:list, resource_name(relationship.destination) <> "List", destination, false}
          else
            destination
          end

        %Member{
          name: relationship.name,
          member: resource_member_name(resource, relationship.name),
          descriptor: descriptor,
          description: relationship.description,
          traits: %{"smithy.api#notProperty" => %{}}
        }
      end)
    else
      []
    end
  end

  @doc """
  Returns the value for a `@default` trait for a static Ash default, or `:error` if the
  default can't be represented, e.g. because it is a function.

  Smithy only allows defaults for simple shapes, enums, and empty lists and maps.
  """
  @spec default_value(Ash.Type.t(), Keyword.t(), descriptor, term) :: {:ok, term} | :error
  def default_value(type, constraints, descriptor, value) do
    with true <- static?(value),
         {:ok, value} when not is_nil(value) <- Ash.Type.cast_input(type, value, constraints) do
      encode_default(descriptor, value)
    else
      _ -> :error
    end
  end

  defp static?(nil), do: false
  defp static?(value) when is_function(value), do: false

  defp static?({module, function, args})
       when is_atom(module) and is_atom(function) and is_list(args), do: false

  defp static?(_), do: true

  defp encode_default({:simple, type, _}, value)
       when type in ["String", "Boolean", "Long", "Integer", "Double"] do
    {:ok, AshSmithy.Codec.encode({:simple, type, %{}}, value)}
  end

  defp encode_default({:simple, "BigDecimal", _}, %Decimal{} = value),
    do: {:ok, Decimal.to_float(value)}

  defp encode_default({:simple, "BigDecimal", _}, value) when is_number(value), do: {:ok, value}

  defp encode_default({:enum, _, values}, value) do
    value = to_string(value)

    if Enum.any?(values, fn {_, enum_value} -> enum_value == value end) do
      {:ok, value}
    else
      :error
    end
  end

  defp encode_default({:list, _, _, _}, []), do: {:ok, []}
  defp encode_default({:map, _, _, _, _}, value) when value == %{}, do: {:ok, %{}}
  defp encode_default(_, _), do: :error

  @doc false
  def resource_name(resource) do
    if AshSmithy.Resource.Info.smithy_resource?(resource) do
      AshSmithy.Resource.Info.name(resource)
    else
      type_name(resource)
    end
  end

  defp resource_fields(resource, definition) do
    if AshSmithy.Resource.Info.smithy_resource?(resource) do
      AshSmithy.Resource.Info.fields(resource)
    else
      definition |> Ash.Info.Manifest.Resource.fields_by_kind(:attribute) |> Enum.map(& &1.name)
    end
  end

  defp resource_member_name(resource, field) do
    if AshSmithy.Resource.Info.smithy_resource?(resource) do
      AshSmithy.Resource.Info.member_name(resource, field)
    else
      AshSmithy.Naming.member_name(field)
    end
  end

  defp fields_members(fields, name, manifest) do
    Enum.map(fields, fn field ->
      %Member{
        name: field.name,
        member: AshSmithy.Naming.member_name(field.name),
        descriptor:
          describe(field.type, name <> AshSmithy.Naming.shape_name(field.name), manifest),
        description: field[:description],
        required?: field[:allow_nil?] == false
      }
    end)
  end

  defp enum(name, values) do
    {:enum, name,
     Enum.map(values, fn value ->
       {enum_member_name(value), to_string(value)}
     end)}
  end

  defp enum_member_name(value) do
    value
    |> to_string()
    |> String.upcase()
    |> String.replace(~r/[^A-Z0-9_]/, "_")
    |> case do
      <<first, _::binary>> = name when first in ?A..?Z -> name
      name -> "V_" <> name
    end
  end

  defp type_name(module) do
    module |> Module.split() |> List.last()
  end

  defp string_traits(constraints) do
    length =
      %{}
      |> maybe_put("min", constraints[:min_length])
      |> maybe_put("max", constraints[:max_length])

    traits =
      if map_size(length) > 0 do
        %{"smithy.api#length" => length}
      else
        %{}
      end

    case constraints[:match] do
      %Regex{} = regex -> Map.put(traits, "smithy.api#pattern", Regex.source(regex))
      pattern when is_binary(pattern) -> Map.put(traits, "smithy.api#pattern", pattern)
      _ -> traits
    end
  end

  defp range_traits(constraints) do
    range =
      %{}
      |> maybe_put("min", constraints[:min])
      |> maybe_put("max", constraints[:max])

    if map_size(range) > 0 do
      %{"smithy.api#range" => range}
    else
      %{}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, %Decimal{} = value), do: Map.put(map, key, Decimal.to_float(value))
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
