defmodule AshSmithy.Plan do
  @moduledoc """
  Compiles the `AshSmithy` DSL into a description of a Smithy service.

  The plan is the single source of truth for both the generated model (`AshSmithy.Model`)
  and request handling (`AshSmithy.Router`).
  """

  alias AshSmithy.Naming
  alias AshSmithy.Type.Member

  defmodule Service do
    @moduledoc "A planned Smithy service."
    defstruct [
      :domain,
      :namespace,
      :name,
      :version,
      :title,
      :description,
      :protocol,
      :prefix,
      resources: [],
      operations: []
    ]
  end

  defmodule Resource do
    @moduledoc "A planned Smithy resource."
    defstruct [
      :resource,
      :name,
      :shape_name,
      :structure,
      :description,
      identifiers: [],
      lifecycle: %{},
      operations: [],
      collection_operations: []
    ]
  end

  defmodule Binding do
    @moduledoc """
    An input member of an operation, along with where it is bound in an HTTP request.

    `source` is one of `:identifier`, `:input`, `:page_token`, `:page_size`, `:filter`,
    `:sort` or `:include`. `location` is one of `:label`, `:query`, `:header` or `:body`.

    `meta` carries source specific information, e.g. the field and operator of a filter.
    """
    defstruct [:member, :source, :location, :location_name, :meta, property?: false]
  end

  defmodule Operation do
    @moduledoc "A planned Smithy operation."
    defstruct [
      :name,
      :kind,
      :binding,
      :resource,
      :resource_name,
      :action,
      :action_type,
      :read_action,
      :result,
      :method,
      :uri,
      :code,
      :description,
      :output,
      :output_member,
      :pagination,
      :metadata,
      readonly?: false,
      idempotent?: false,
      input: [],
      output_members: [],
      errors: []
    ]

    @type output :: :record | :records | :empty | :result
  end

  @not_found "NotFoundException"

  @doc "Plans the service for a domain."
  @spec service(Ash.Domain.t()) :: Service.t()
  def service(domain) do
    resources = Enum.map(AshSmithy.Domain.Info.resources(domain), &resource(domain, &1))

    %Service{
      domain: domain,
      namespace: AshSmithy.Domain.Info.smithy_namespace!(domain),
      name: AshSmithy.Domain.Info.service(domain),
      version: value(AshSmithy.Domain.Info.smithy_version(domain)),
      title: value(AshSmithy.Domain.Info.smithy_title(domain)),
      description: AshSmithy.Domain.Info.description(domain),
      protocol: AshSmithy.Domain.Info.smithy_protocol!(domain),
      prefix: AshSmithy.Domain.Info.smithy_prefix!(domain),
      resources: Enum.map(resources, &elem(&1, 0)),
      operations: Enum.flat_map(resources, &elem(&1, 1))
    }
  end

  defp value({:ok, value}), do: value
  defp value(:error), do: nil

  @doc "The name of the Smithy operation for a DSL operation."
  @spec operation_name(Ash.Resource.t(), AshSmithy.Resource.Operation.t()) :: String.t()
  def operation_name(resource, %{name: nil} = operation) do
    name = AshSmithy.Resource.Info.name(resource)

    case operation.kind do
      :create ->
        "Create" <> name

      :read ->
        "Get" <> name

      :update ->
        "Update" <> name

      :delete ->
        "Delete" <> name

      :list ->
        "List" <> AshSmithy.Resource.Info.plural_name(resource)

      :collection_operation ->
        Naming.shape_name(operation.action) <> AshSmithy.Resource.Info.plural_name(resource)

      :operation ->
        Naming.shape_name(operation.action) <> name
    end
  end

  def operation_name(_resource, operation), do: operation.name

  defp resource(domain, resource) do
    name = AshSmithy.Resource.Info.name(resource)
    structure = AshSmithy.Type.resource_structure(resource)
    {:structure, _, properties} = structure

    identifiers =
      resource
      |> AshSmithy.Resource.Info.identifiers()
      |> Enum.map(fn name ->
        %{
          attribute_member(resource, name)
          | member: AshSmithy.Resource.Info.identifier_name(resource, name)
        }
      end)

    operations =
      resource
      |> AshSmithy.Resource.Info.operations()
      |> Enum.map(&operation(domain, resource, &1, identifiers, properties))

    planned = %Resource{
      resource: resource,
      name: name,
      shape_name: name <> "Resource",
      structure: structure,
      description: AshSmithy.Resource.Info.description(resource),
      identifiers: identifiers,
      lifecycle:
        operations
        |> Enum.filter(&(&1.binding not in [:operation, :collection_operation]))
        |> Map.new(&{&1.binding, &1.name}),
      operations: for(%{binding: :operation} = op <- operations, do: op.name),
      collection_operations:
        for(%{binding: :collection_operation} = op <- operations, do: op.name)
    }

    {planned, operations}
  end

  defp operation(domain, resource, operation, identifiers, properties) do
    action = Ash.Resource.Info.action(resource, operation.action)
    name = operation_name(resource, operation)
    instance? = operation.kind in [:read, :update, :delete, :operation]
    readonly? = action.type == :read or (action.type == :action and operation.readonly?)
    output = output(operation, action)
    pagination = pagination(operation, action)

    binding =
      case operation.kind do
        :delete -> if operation.idempotent?, do: :delete, else: :operation
        kind -> kind
      end

    method = operation.method || default_method(operation, action)

    uri =
      AshSmithy.Domain.Info.smithy_prefix!(domain) <>
        AshSmithy.Resource.Info.base_path(resource) <>
        (operation.path || default_path(operation, identifiers, instance?))

    uri =
      case String.trim_trailing(uri, "/") do
        "" -> "/"
        uri -> uri
      end

    # Members of operations that Smithy checks against the resource's properties must either
    # be a property, an identifier, or be marked with `@notProperty`.
    property_names =
      if property_checked?(binding) do
        identifier_names = MapSet.new(identifiers, & &1.name)

        properties
        |> Enum.reject(&MapSet.member?(identifier_names, &1.name))
        |> MapSet.new(& &1.name)
      else
        MapSet.new()
      end

    input =
      Enum.concat([
        if(instance?, do: Enum.map(identifiers, &identifier_binding/1), else: []),
        action_bindings(resource, action, name, operation, method, property_names),
        pagination_bindings(pagination),
        AshSmithy.Plan.Query.bindings(resource, operation, action, name, output, pagination)
      ])

    verify_unique_members!(resource, operation, name, input)

    verify_uri_labels!(resource, name, uri, input)

    operation = %Operation{
      name: name,
      kind: operation.kind,
      binding: binding,
      resource: resource,
      resource_name: AshSmithy.Resource.Info.name(resource),
      action: action.name,
      action_type: action.type,
      result:
        if output == :result do
          %Member{
            name: :result,
            member: "result",
            descriptor:
              AshSmithy.Type.describe(action.returns, action.constraints, name <> "Result"),
            required?: Map.get(action, :allow_nil?, true) == false
          }
        end,
      read_action:
        if instance? and action.type != :read do
          operation.read_action || Ash.Resource.Info.primary_action!(resource, :read).name
        end,
      method: method,
      uri: uri,
      code: operation.code || 200,
      description: operation.description || action.description,
      output: output,
      output_member: output_member(resource, output),
      metadata: metadata(resource, action, name, output),
      pagination: pagination,
      readonly?: readonly?,
      idempotent?: operation.idempotent? and not readonly?,
      input: input,
      errors: if(instance?, do: [@not_found], else: [])
    }

    %{operation | output_members: output_members(operation)}
  end

  # The members of the output structure, all bound to the body. The values for each member
  # are built by `AshSmithy.Executor.output/2`.
  defp output_members(%Operation{} = operation) do
    body(
      case operation.output do
        :record ->
          [
            %Member{
              name: :record,
              member: operation.output_member,
              descriptor: {:resource, operation.resource},
              required?: true,
              traits:
                if property_checked?(operation.binding) do
                  %{"smithy.api#nestedProperties" => %{}}
                else
                  %{}
                end
            }
          ]

        :records ->
          [
            %Member{
              name: :items,
              member: operation.output_member,
              descriptor: items_descriptor(operation),
              required?: true
            }
          ] ++
            if operation.pagination do
              [
                %Member{
                  name: :next_token,
                  member: "nextToken",
                  descriptor: {:simple, "String", %{}},
                  description:
                    "A token to fetch the next page of results. Absent when there are no more results."
                }
              ]
            else
              []
            end

        :result ->
          [operation.result]

        :empty ->
          []
      end ++ metadata_members(operation)
    )
  end

  defp body(members) do
    Enum.map(
      members,
      &%Binding{member: &1, source: :output, location: :body, location_name: &1.member}
    )
  end

  # Metadata is per record, so when there is metadata each item pairs a record with its metadata.
  defp items_descriptor(%Operation{metadata: nil} = operation) do
    {:list, operation.resource_name <> "List", {:resource, operation.resource}, false}
  end

  defp items_descriptor(%Operation{} = operation) do
    item = operation.name <> "Item"

    {:list, item <> "List",
     {:structure, item,
      [
        %Member{
          name: :record,
          member: item_member(operation),
          descriptor: {:resource, operation.resource},
          required?: true
        },
        %Member{name: :metadata, member: "metadata", descriptor: operation.metadata}
      ]}, false}
  end

  defp metadata_members(%Operation{metadata: nil}), do: []
  defp metadata_members(%Operation{output: :records}), do: []

  defp metadata_members(%Operation{} = operation) do
    [
      %Member{
        name: :metadata,
        member: "metadata",
        descriptor: operation.metadata,
        traits:
          if property_checked?(operation.binding) do
            %{"smithy.api#notProperty" => %{}}
          else
            %{}
          end
      }
    ]
  end

  @doc "Whether Smithy validates the members of an operation with this binding against the resource's properties."
  def property_checked?(binding), do: binding not in [:list, :collection_operation]

  defp output(operation, action) do
    case {operation.kind, action.type} do
      {_, :destroy} -> :empty
      {:list, :read} -> :records
      {:collection_operation, :read} -> :records
      {_, :action} -> if action.returns, do: :result, else: :empty
      _ -> :record
    end
  end

  # Action metadata is returned alongside the record(s) as a `metadata` structure.
  defp metadata(_resource, _action, _name, output) when output not in [:record, :records, :empty],
    do: nil

  defp metadata(resource, action, name, _output) do
    case Map.get(action, :metadata, []) do
      [] ->
        nil

      metadata ->
        {:structure, name <> "Metadata",
         Enum.map(metadata, fn metadata ->
           %Member{
             name: metadata.name,
             member: AshSmithy.Resource.Info.member_name(resource, metadata.name),
             descriptor:
               AshSmithy.Type.describe(
                 metadata.type,
                 metadata.constraints,
                 name <> "Metadata" <> Naming.shape_name(metadata.name)
               ),
             description: metadata.description,
             required?: metadata.allow_nil? == false
           }
         end)}
    end
  end

  defp output_member(resource, :record) do
    Naming.member_name(Macro.underscore(AshSmithy.Resource.Info.name(resource)))
  end

  defp output_member(resource, :records) do
    Naming.member_name(Macro.underscore(AshSmithy.Resource.Info.plural_name(resource)))
  end

  defp output_member(_resource, :result), do: "result"
  defp output_member(_resource, :empty), do: nil

  @doc "The member naming a single record, used for list items that carry metadata."
  def item_member(%Operation{resource: resource}), do: output_member(resource, :record)

  defp pagination(%{kind: :list, paginated?: false}, _action), do: nil

  defp pagination(%{kind: kind}, %{type: :read, pagination: %{} = pagination})
       when kind in [:list, :collection_operation] do
    %{
      type: if(pagination.keyset?, do: :keyset, else: :offset),
      default_limit: pagination.default_limit,
      max_page_size: pagination.max_page_size
    }
  end

  defp pagination(_, _), do: nil

  defp pagination_bindings(nil), do: []

  defp pagination_bindings(pagination) do
    range =
      if pagination.max_page_size do
        %{"min" => 1, "max" => pagination.max_page_size}
      else
        %{"min" => 1}
      end

    [
      %Binding{
        member: %Member{
          name: :next_token,
          member: "nextToken",
          descriptor: {:simple, "String", %{}},
          description: "A token returned by a previous request, used to fetch the next page."
        },
        source: :page_token,
        location: :query,
        location_name: "nextToken"
      },
      %Binding{
        member: %Member{
          name: :max_results,
          member: "maxResults",
          descriptor: {:simple, "Integer", %{"smithy.api#range" => range}},
          description: "The maximum number of results to return."
        },
        source: :page_size,
        location: :query,
        location_name: "maxResults"
      }
    ]
  end

  defp default_method(operation, action) do
    case {operation.kind, action.type} do
      {:create, _} -> "POST"
      {:read, _} -> "GET"
      {:update, _} -> "PATCH"
      {:delete, _} -> "DELETE"
      {:list, _} -> "GET"
      {_, :read} -> "GET"
      _ -> "POST"
    end
  end

  defp default_path(operation, identifiers, instance?) do
    labels = Enum.map_join(identifiers, &"/{#{&1.member}}")

    case operation.kind do
      kind when kind in [:read, :update, :delete] ->
        labels

      :operation ->
        labels <> "/" <> Naming.dasherize(Naming.shape_name(operation.action))

      :collection_operation ->
        "/" <> Naming.dasherize(Naming.shape_name(operation.action))

      _ ->
        if instance?, do: labels, else: ""
    end
  end

  defp identifier_binding(member) do
    %Binding{
      member: %{member | required?: true},
      source: :identifier,
      location: :label,
      location_name: member.member
    }
  end

  defp attribute_member(resource, name) do
    attribute = Ash.Resource.Info.attribute(resource, name)
    resource_name = AshSmithy.Resource.Info.name(resource)

    descriptor =
      AshSmithy.Type.describe(
        attribute.type,
        attribute.constraints,
        resource_name <> Naming.shape_name(attribute.name)
      )

    %Member{
      name: attribute.name,
      member: AshSmithy.Resource.Info.member_name(resource, attribute.name),
      descriptor:
        if name in AshSmithy.Resource.Info.identifiers(resource) do
          AshSmithy.Type.identifier_descriptor(descriptor)
        else
          descriptor
        end,
      description: attribute.description
    }
  end

  defp action_bindings(resource, action, operation_name, operation, method, property_names) do
    body? = method not in ["GET", "DELETE", "HEAD"]
    query = MapSet.new(List.wrap(operation.query))
    headers = Map.new(operation.headers)

    action
    |> action_members(resource, operation_name)
    |> Enum.map(fn member ->
      {location, location_name} =
        cond do
          Map.has_key?(headers, member.name) -> {:header, headers[member.name]}
          MapSet.member?(query, member.name) or not body? -> {:query, member.member}
          true -> {:body, member.member}
        end

      if location in [:query, :header] and not string_bindable?(member.descriptor) do
        raise Spark.Error.DslError,
          module: resource,
          path: [:smithy, :operations, operation.kind, operation.action],
          message: """
          Input #{inspect(member.name)} of #{operation_name} cannot be bound to the #{location}, because its type cannot be serialized as a string.

          Use a method that supports a request body, e.g. `method: "POST"`.
          """
      end

      %Binding{
        member: member,
        source: :input,
        location: location,
        location_name: location_name,
        property?: MapSet.member?(property_names, member.name)
      }
    end)
  end

  defp action_members(action, resource, operation_name) do
    attributes =
      action
      |> Map.get(:accept, [])
      |> List.wrap()
      |> Enum.map(fn name ->
        attribute = Ash.Resource.Info.attribute(resource, name)

        member = attribute_member(resource, name)

        # Attribute defaults only apply on create
        default = if action.type == :create, do: attribute.default

        %{
          member
          | required?: attribute_required?(action, attribute),
            traits: default_traits(attribute, member.descriptor, default)
        }
      end)

    arguments =
      action.arguments
      |> Enum.filter(&Map.get(&1, :public?, true))
      |> Enum.map(fn argument ->
        descriptor =
          AshSmithy.Type.describe(
            argument.type,
            argument.constraints,
            operation_name <> Naming.shape_name(argument.name)
          )

        # Smithy discourages defaults in update inputs, since they look like partial updates
        default = if action.type != :update, do: argument.default

        %Member{
          name: argument.name,
          member: AshSmithy.Resource.Info.member_name(resource, argument.name),
          descriptor: descriptor,
          description: argument.description,
          required?: argument.allow_nil? == false and is_nil(argument.default),
          traits: default_traits(argument, descriptor, default)
        }
      end)

    attributes ++ arguments
  end

  defp default_traits(field, descriptor, default) do
    case AshSmithy.Type.default_value(field.type, field.constraints, descriptor, default) do
      {:ok, value} -> %{"smithy.api#default" => value}
      :error -> %{}
    end
  end

  defp attribute_required?(%{type: :create} = action, attribute) do
    attribute.name in List.wrap(Map.get(action, :require_attributes)) or
      (attribute.allow_nil? == false and is_nil(attribute.default) and not attribute.generated? and
         attribute.name not in List.wrap(Map.get(action, :allow_nil_input)))
  end

  defp attribute_required?(action, attribute) do
    attribute.name in List.wrap(Map.get(action, :require_attributes))
  end

  defp string_bindable?({:simple, type, _}) when type != "Document", do: true
  defp string_bindable?({:enum, _, _}), do: true

  defp string_bindable?({:list, _, member, _}),
    do: string_bindable?(member) and not match?({:list, _, _, _}, member)

  defp string_bindable?(_), do: false

  defp verify_unique_members!(resource, operation, operation_name, input) do
    input
    |> Enum.group_by(& &1.member.member)
    |> Enum.find(fn {_member, bindings} -> Enum.count(bindings) > 1 end)
    |> case do
      nil ->
        :ok

      {member, bindings} ->
        raise Spark.Error.DslError,
          module: resource,
          path: [:smithy, :operations, operation.kind, operation.action],
          message: """
          #{operation_name} has multiple inputs named `#{member}` (from #{Enum.map_join(bindings, ", ", &inspect(&1.source))}).

          Rename the action input with `member_names`, or exclude the field from `filter`.
          """
    end
  end

  defp verify_uri_labels!(resource, operation_name, uri, input) do
    labels =
      ~r/\{([^}+]+)\+?\}/
      |> Regex.scan(uri, capture: :all_but_first)
      |> List.flatten()

    label_members = for %{location: :label} = binding <- input, do: binding.member.member

    case {labels -- label_members, label_members -- labels} do
      {[], []} ->
        :ok

      {extra, missing} ->
        raise Spark.Error.DslError,
          module: resource,
          path: [:smithy, :operations],
          message: """
          The path of #{operation_name} (#{uri}) does not match its identifiers.

          #{if extra != [], do: "Unknown labels: #{Enum.join(extra, ", ")}\n"}#{if missing != [], do: "Missing labels: #{Enum.join(missing, ", ")}"}
          """
    end
  end
end
