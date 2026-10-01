defmodule AshSmithy.Model do
  @moduledoc """
  Generates a Smithy model, in the [JSON AST](https://smithy.io/2.0/spec/json-ast.html) format,
  for one or more domains using `AshSmithy.Domain`.
  """

  alias AshSmithy.Plan

  @prelude "smithy.api#"

  @doc "Builds the Smithy JSON AST for the given domain or domains, as a map."
  @spec build(Ash.Domain.t() | [Ash.Domain.t()]) :: map
  def build(domains) do
    shapes =
      domains
      |> List.wrap()
      |> Enum.map(&Plan.service/1)
      |> Enum.reduce(%{}, &service_shapes/2)

    %{"smithy" => "2.0", "shapes" => shapes}
  end

  @doc "Builds the Smithy JSON AST for the given domain or domains, encoded as JSON."
  @spec to_json(Ash.Domain.t() | [Ash.Domain.t()], Keyword.t()) :: String.t()
  def to_json(domains, opts \\ []) do
    domains
    |> build()
    |> ordered()
    |> Jason.encode!(pretty: Keyword.get(opts, :pretty, true))
  end

  # Sort keys so that generated models are stable and diffable.
  defp ordered(map) when is_map(map) do
    map
    |> Enum.sort_by(fn {key, _} -> key end)
    |> Enum.map(fn {key, value} -> {key, ordered(value)} end)
    |> Jason.OrderedObject.new()
  end

  defp ordered(list) when is_list(list), do: Enum.map(list, &ordered/1)
  defp ordered(value), do: value

  defp service_shapes(%Plan.Service{} = service, shapes) do
    ns = service.namespace
    shapes = error_shapes(ns, shapes)

    shapes =
      put_shape(shapes, id(ns, service.name), %{
        "type" => "service",
        "version" => service.version,
        "resources" => Enum.map(service.resources, &ref(ns, &1.shape_name)),
        "errors" =>
          Enum.map(
            ["ValidationException", "ForbiddenException", "InternalServerError"],
            &ref(ns, &1)
          ),
        "traits" =>
          %{protocol_trait(service.protocol) => %{}}
          |> put_trait("title", service.title)
          |> put_trait("documentation", service.description)
      })
      |> remove_nil_keys(id(ns, service.name))

    shapes = Enum.reduce(service.resources, shapes, &resource_shapes(ns, service, &1, &2))
    Enum.reduce(service.operations, shapes, &operation_shapes(ns, &1, &2))
  end

  defp protocol_trait(:rest_json1), do: "aws.protocols#restJson1"

  defp resource_shapes(ns, service, %Plan.Resource{} = resource, shapes) do
    {:structure, _name, properties} = resource.structure
    identifier_names = MapSet.new(resource.identifiers, & &1.name)
    {_, _, shapes} = target(ns, {:resource, resource.resource}, shapes)

    {identifiers, shapes} =
      Enum.map_reduce(resource.identifiers, shapes, fn member, shapes ->
        {target, _traits, shapes} = target(ns, member.descriptor, shapes)
        {{member.member, %{"target" => target}}, shapes}
      end)

    {properties, shapes} =
      properties
      |> Enum.reject(&MapSet.member?(identifier_names, &1.name))
      |> Enum.reject(&Map.has_key?(&1.traits, "smithy.api#notProperty"))
      |> Enum.map_reduce(shapes, fn member, shapes ->
        {target, _traits, shapes} = target(ns, member.descriptor, shapes)
        {{member.member, %{"target" => target}}, shapes}
      end)

    operations = Map.new(service.operations, &{&1.name, &1})

    shape =
      resource.lifecycle
      |> Map.new(fn {binding, name} -> {to_string(binding), ref(ns, name)} end)
      |> Map.merge(%{
        "type" => "resource",
        "identifiers" => Map.new(identifiers),
        "properties" => Map.new(properties),
        "operations" => Enum.map(resource.operations, &ref(ns, operations[&1].name)),
        "collectionOperations" =>
          Enum.map(resource.collection_operations, &ref(ns, operations[&1].name))
      })
      |> Map.reject(fn {_, value} -> value == [] or value == %{} end)
      |> put_traits(%{} |> put_trait("documentation", resource.description))

    put_shape(shapes, id(ns, resource.shape_name), shape)
  end

  defp operation_shapes(ns, %Plan.Operation{} = operation, shapes) do
    input_name = operation.name <> "Input"
    output_name = operation.name <> "Output"

    {input_members, shapes} =
      Enum.map_reduce(operation.input, shapes, fn binding, shapes ->
        {member, shapes} = member(ns, binding.member, shapes)

        traits =
          member
          |> Map.get("traits", %{})
          |> Map.merge(binding_traits(binding))
          |> then(fn traits ->
            if binding.source != :identifier and not binding.property? and
                 Plan.property_checked?(operation.binding) do
              Map.put(traits, @prelude <> "notProperty", %{})
            else
              traits
            end
          end)

        {{binding.member.member, put_traits(member, traits)}, shapes}
      end)

    shapes =
      put_shape(shapes, id(ns, input_name), %{
        "type" => "structure",
        "members" => Map.new(input_members),
        "traits" =>
          put_references(
            %{(@prelude <> "input") => %{}},
            ns,
            operation.resource,
            for(%{source: :input} = binding <- operation.input, do: binding.member)
          )
      })

    {output_members, shapes} = output_members(ns, operation, shapes)

    shapes =
      put_shape(shapes, id(ns, output_name), %{
        "type" => "structure",
        "members" => output_members,
        "traits" => %{(@prelude <> "output") => %{}}
      })

    traits =
      %{
        (@prelude <> "http") => %{
          "method" => operation.method,
          "uri" => operation.uri,
          "code" => operation.code
        }
      }
      |> put_trait("documentation", operation.description)
      |> then(&if operation.readonly?, do: Map.put(&1, @prelude <> "readonly", %{}), else: &1)
      |> then(&if operation.idempotent?, do: Map.put(&1, @prelude <> "idempotent", %{}), else: &1)
      |> then(fn traits ->
        if operation.pagination do
          Map.put(traits, @prelude <> "paginated", %{
            "inputToken" => "nextToken",
            "outputToken" => "nextToken",
            "pageSize" => "maxResults",
            "items" => operation.output_member
          })
        else
          traits
        end
      end)

    put_shape(
      shapes,
      id(ns, operation.name),
      %{
        "type" => "operation",
        "input" => ref(ns, input_name),
        "output" => ref(ns, output_name),
        "traits" => traits
      }
      |> then(fn shape ->
        if operation.errors == [] do
          shape
        else
          Map.put(shape, "errors", Enum.map(operation.errors, &ref(ns, &1)))
        end
      end)
    )
  end

  defp binding_traits(%{location: :label}), do: %{(@prelude <> "httpLabel") => %{}}

  defp binding_traits(%{location: :query, location_name: name}),
    do: %{(@prelude <> "httpQuery") => name}

  defp binding_traits(%{location: :header, location_name: name}),
    do: %{(@prelude <> "httpHeader") => name}

  defp binding_traits(%{location: :body}), do: %{}

  defp output_members(ns, operation, shapes) do
    {members, shapes} =
      Enum.map_reduce(operation.output_members, shapes, fn binding, shapes ->
        {member, shapes} = member(ns, binding.member, shapes)
        {{binding.member.member, member}, shapes}
      end)

    {Map.new(members), shapes}
  end

  defp member(ns, %AshSmithy.Type.Member{} = member, shapes) do
    {target, traits, shapes} = target(ns, member.descriptor, shapes)

    traits =
      traits
      |> then(&if member.required?, do: Map.put(&1, @prelude <> "required", %{}), else: &1)
      |> put_trait("documentation", member.description)
      |> Map.merge(member.traits || %{})

    {put_traits(%{"target" => target}, traits), shapes}
  end

  defp target(_ns, {:simple, type, traits}, shapes), do: {@prelude <> type, traits, shapes}

  defp target(ns, {:enum, name, values}, shapes) do
    shape = %{
      "type" => "enum",
      "members" =>
        Map.new(values, fn {member, value} ->
          {member,
           %{
             "target" => @prelude <> "Unit",
             "traits" => %{(@prelude <> "enumValue") => value}
           }}
        end)
    }

    {id(ns, name), %{}, put_shape(shapes, id(ns, name), shape)}
  end

  defp target(ns, {:list, name, member, sparse?}, shapes) do
    {member_target, member_traits, shapes} = target(ns, member, shapes)

    shape =
      %{"type" => "list", "member" => put_traits(%{"target" => member_target}, member_traits)}
      |> then(&if sparse?, do: put_traits(&1, %{(@prelude <> "sparse") => %{}}), else: &1)

    {id(ns, name), %{}, put_shape(shapes, id(ns, name), shape)}
  end

  defp target(ns, {:map, name, key, value, sparse?}, shapes) do
    {key_target, key_traits, shapes} = target(ns, key, shapes)
    {value_target, value_traits, shapes} = target(ns, value, shapes)

    shape =
      %{
        "type" => "map",
        "key" => put_traits(%{"target" => key_target}, key_traits),
        "value" => put_traits(%{"target" => value_target}, value_traits)
      }
      |> then(&if sparse?, do: put_traits(&1, %{(@prelude <> "sparse") => %{}}), else: &1)

    {id(ns, name), %{}, put_shape(shapes, id(ns, name), shape)}
  end

  defp target(ns, {:int_enum, name, values}, shapes) do
    shape = %{
      "type" => "intEnum",
      "members" =>
        Map.new(values, fn {member, value} ->
          {member,
           %{"target" => @prelude <> "Unit", "traits" => %{(@prelude <> "enumValue") => value}}}
        end)
    }

    {id(ns, name), %{}, put_shape(shapes, id(ns, name), shape)}
  end

  defp target(ns, {:resource, resource}, shapes) do
    {:structure, name, _} = structure = AshSmithy.Type.resource_structure(resource)

    if Map.has_key?(shapes, id(ns, name)) do
      {id(ns, name), %{}, shapes}
    else
      {:structure, _, members} = structure
      {target, traits, shapes} = target(ns, structure, shapes)

      shapes =
        Map.update!(shapes, target, fn shape ->
          case put_references(%{}, ns, resource, members) do
            references when references == %{} -> shape
            references -> put_traits(shape, references)
          end
        end)

      {target, traits, shapes}
    end
  end

  defp target(ns, {type, name, members}, shapes) when type in [:structure, :union] do
    shape_id = id(ns, name)

    if Map.has_key?(shapes, shape_id) do
      # Already generated (or being generated, for recursive shapes).
      {shape_id, %{}, shapes}
    else
      # Insert a placeholder so recursive references terminate.
      shapes = Map.put(shapes, shape_id, :pending)

      {members, shapes} =
        Enum.map_reduce(members, shapes, fn member, shapes ->
          {encoded, shapes} =
            member(ns, %{member | required?: member.required? and type == :structure}, shapes)

          {{member.member, encoded}, shapes}
        end)

      shape = %{"type" => to_string(type), "members" => Map.new(members)}
      {shape_id, %{}, Map.put(shapes, shape_id, shape)}
    end
  end

  # Members holding the attribute of a `belongs_to` relationship reference the destination
  # resource, when it is part of the same service.
  defp put_references(traits, ns, resource, members) do
    member_names = Map.new(members, &{&1.name, &1.member})

    references =
      resource
      |> Ash.Resource.Info.relationships()
      |> Enum.filter(fn relationship ->
        relationship.type == :belongs_to and
          Map.has_key?(member_names, relationship.source_attribute) and
          AshSmithy.Resource.Info.smithy_resource?(relationship.destination) and
          Ash.Resource.Info.domain(relationship.destination) == Ash.Resource.Info.domain(resource) and
          AshSmithy.Resource.Info.identifiers(relationship.destination) == [
            relationship.destination_attribute
          ]
      end)
      |> Enum.map(fn relationship ->
        destination = relationship.destination

        %{
          "resource" => id(ns, AshSmithy.Resource.Info.name(destination) <> "Resource"),
          "ids" => %{
            AshSmithy.Resource.Info.identifier_name(
              destination,
              relationship.destination_attribute
            ) => member_names[relationship.source_attribute]
          }
        }
      end)

    if references == [] do
      traits
    else
      Map.put(traits, @prelude <> "references", references)
    end
  end

  defp error_shapes(ns, shapes) do
    message = %{"target" => @prelude <> "String", "traits" => %{(@prelude <> "required") => %{}}}

    error = fn kind, code, doc, members ->
      %{
        "type" => "structure",
        "members" => Map.merge(%{"message" => message}, members),
        "traits" => %{
          (@prelude <> "error") => kind,
          (@prelude <> "httpError") => code,
          (@prelude <> "documentation") => doc
        }
      }
    end

    shapes
    |> put_shape(
      id(ns, "ValidationException"),
      error.("client", 400, "The input failed to satisfy the constraints of the operation.", %{
        "fieldList" => %{
          "target" => id(ns, "ValidationExceptionFieldList"),
          "traits" => %{
            (@prelude <> "documentation") =>
              "A list of the specific fields that failed validation."
          }
        }
      })
    )
    |> put_shape(id(ns, "ValidationExceptionFieldList"), %{
      "type" => "list",
      "member" => %{"target" => id(ns, "ValidationExceptionField")}
    })
    |> put_shape(id(ns, "ValidationExceptionField"), %{
      "type" => "structure",
      "members" => %{
        "path" => %{
          "target" => @prelude <> "String",
          "traits" => %{
            (@prelude <> "required") => %{},
            (@prelude <> "documentation") => "A JSON pointer to the invalid input member."
          }
        },
        "message" => message
      }
    })
    |> put_shape(
      id(ns, "ForbiddenException"),
      error.("client", 403, "The caller is not authorized to perform the operation.", %{})
    )
    |> put_shape(
      id(ns, "NotFoundException"),
      error.("client", 404, "The requested resource could not be found.", %{})
    )
    |> put_shape(
      id(ns, "InternalServerError"),
      error.("server", 500, "An unexpected error occurred while processing the request.", %{})
    )
  end

  defp put_shape(shapes, shape_id, shape) do
    case Map.fetch(shapes, shape_id) do
      {:ok, ^shape} ->
        shapes

      {:ok, :pending} ->
        Map.put(shapes, shape_id, shape)

      {:ok, existing} ->
        raise ArgumentError, """
        Conflicting definitions generated for Smithy shape #{shape_id}.

        Existing: #{inspect(existing)}

        New: #{inspect(shape)}

        Rename one of the types or fields that produce this shape.
        """

      :error ->
        Map.put(shapes, shape_id, shape)
    end
  end

  defp remove_nil_keys(shapes, shape_id) do
    Map.update!(shapes, shape_id, fn shape -> Map.reject(shape, fn {_, v} -> is_nil(v) end) end)
  end

  defp put_trait(traits, _name, nil), do: traits
  defp put_trait(traits, name, value), do: Map.put(traits, @prelude <> name, value)

  defp put_traits(shape, traits) when map_size(traits) == 0, do: shape

  defp put_traits(shape, traits) do
    Map.update(shape, "traits", traits, &Map.merge(&1, traits))
  end

  defp ref(ns, name), do: %{"target" => id(ns, name)}
  defp id(ns, name), do: ns <> "#" <> name
end
