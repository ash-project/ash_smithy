defmodule AshSmithy.Type do
  @moduledoc """
  Maps Ash types to Smithy type descriptors.

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
  Returns the descriptor for an Ash type.

  `name` is used to name any shapes that must be generated for the type, e.g. an enum for an
  atom attribute with `one_of` constraints.
  """
  @spec describe(Ash.Type.t(), Keyword.t(), String.t()) :: descriptor
  def describe(type, constraints, name) do
    type = Ash.Type.get_type(type)
    constraints = constraints || []

    cond do
      match?({:array, _}, type) ->
        {:array, item_type} = type
        item_constraints = constraints[:items] || []

        {:list, name <> "List", describe(item_type, item_constraints, name <> "Item"),
         constraints[:nil_items?] == true}

      is_atom(type) and Code.ensure_loaded?(type) and function_exported?(type, :smithy_type, 1) ->
        type.smithy_type(constraints)

      Ash.Type.embedded_type?(type) ->
        {:resource, type}

      Spark.implements_behaviour?(type, Ash.Type.Enum) ->
        enum(type_name(type), type.values())

      Ash.Type.NewType.new_type?(type) ->
        describe(
          Ash.Type.NewType.subtype_of(type),
          Ash.Type.NewType.constraints(type, constraints),
          type_name(type)
        )

      true ->
        describe_builtin(type, constraints, name)
    end
  end

  defp describe_builtin(type, constraints, name) do
    case type do
      type when type in [Ash.Type.String, Ash.Type.CiString] ->
        {:simple, "String", string_traits(constraints)}

      Ash.Type.Atom ->
        case constraints[:one_of] do
          values when is_list(values) and values != [] -> enum(name, values)
          _ -> {:simple, "String", %{}}
        end

      type when type in [Ash.Type.UUID, Ash.Type.UUIDv7] ->
        {:simple, "String", %{}}

      Ash.Type.Integer ->
        {:simple, "Long", range_traits(constraints)}

      Ash.Type.Float ->
        {:simple, "Double", range_traits(constraints)}

      Ash.Type.Decimal ->
        {:simple, "BigDecimal", range_traits(constraints)}

      Ash.Type.Boolean ->
        {:simple, "Boolean", %{}}

      Ash.Type.Binary ->
        {:simple, "Blob", %{}}

      type
      when type in [
             Ash.Type.UtcDatetime,
             Ash.Type.UtcDatetimeUsec,
             Ash.Type.DateTime,
             Ash.Type.NaiveDatetime
           ] ->
        {:simple, "Timestamp", @timestamp_traits}

      type when type in [Ash.Type.Date, Ash.Type.Time, Ash.Type.TimeUsec, Ash.Type.Duration] ->
        {:simple, "String", %{}}

      type when type in [Ash.Type.Map, Ash.Type.Keyword, Ash.Type.Struct] ->
        cond do
          type == Ash.Type.Struct && constraints[:instance_of] &&
              Ash.Resource.Info.resource?(constraints[:instance_of]) ->
            {:resource, constraints[:instance_of]}

          constraints[:fields] ->
            {:structure, name, fields_members(constraints[:fields], name)}

          # Keyword lists can't be round tripped through JSON objects without fields
          type == Ash.Type.Keyword ->
            {:simple, "Document", %{}}

          # Ash only accepts objects for maps, so this is more precise than a bare document
          true ->
            {:map, name, {:simple, "String", %{}}, {:simple, "Document", %{}}, false}
        end

      Ash.Type.Union ->
        members =
          constraints
          |> Keyword.get(:types, [])
          |> Enum.map(fn {type_name, config} ->
            %Member{
              name: type_name,
              member: AshSmithy.Naming.member_name(type_name),
              descriptor:
                describe(
                  config[:type],
                  config[:constraints] || [],
                  name <> AshSmithy.Naming.shape_name(type_name)
                ),
              description: config[:description]
            }
          end)

        {:union, name, members}

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

  @doc "The descriptor for a resource's structure shape."
  @spec resource_structure(Ash.Resource.t()) :: descriptor
  def resource_structure(resource) do
    name = resource_name(resource)

    identifiers =
      if AshSmithy.Resource.Info.smithy_resource?(resource) do
        AshSmithy.Resource.Info.identifiers(resource)
      else
        []
      end

    members =
      resource
      |> resource_fields()
      |> Enum.map(fn field_name ->
        field = Ash.Resource.Info.field(resource, field_name)

        descriptor =
          describe(field.type, field.constraints, name <> AshSmithy.Naming.shape_name(field.name))

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
            required?: Map.get(field, :allow_nil?, true) == false,
            # Calculations and aggregates are derived, so they are not properties of the resource
            traits:
              if Ash.Resource.Info.attribute(resource, field.name) do
                %{}
              else
                %{"smithy.api#notProperty" => %{}}
              end
          }
        end
      end)

    {:structure, name, members ++ relationship_members(resource)}
  end

  # Exposed relationships are optional members, only present when included.
  defp relationship_members(resource) do
    if AshSmithy.Resource.Info.smithy_resource?(resource) do
      resource
      |> AshSmithy.Resource.Info.relationships()
      |> Enum.map(fn relationship ->
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

  defp resource_fields(resource) do
    if AshSmithy.Resource.Info.smithy_resource?(resource) do
      AshSmithy.Resource.Info.fields(resource)
    else
      resource |> Ash.Resource.Info.public_attributes() |> Enum.map(& &1.name)
    end
  end

  defp resource_member_name(resource, field) do
    if AshSmithy.Resource.Info.smithy_resource?(resource) do
      AshSmithy.Resource.Info.member_name(resource, field)
    else
      AshSmithy.Naming.member_name(field)
    end
  end

  defp fields_members(fields, name) do
    Enum.map(fields, fn {field_name, config} ->
      %Member{
        name: field_name,
        member: AshSmithy.Naming.member_name(field_name),
        descriptor:
          describe(
            config[:type],
            config[:constraints] || [],
            name <> AshSmithy.Naming.shape_name(field_name)
          ),
        description: config[:description],
        required?: config[:allow_nil?] == false
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
