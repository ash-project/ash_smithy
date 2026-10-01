defmodule AshSmithy.Plan.Query do
  @moduledoc false
  # Plans the query parameters derived from the resource rather than the action:
  # filters and sorts for operations that return lists, and includes for operations that
  # return records.

  alias AshSmithy.Naming
  alias AshSmithy.Plan.Binding
  alias AshSmithy.Type.Member

  @comparable ["Long", "Integer", "Double", "BigDecimal", "BigInteger", "Timestamp"]

  def bindings(resource, operation, action, operation_name, output, pagination) do
    list? = output == :records and action.type == :read

    Enum.concat([
      if(list?, do: filter_bindings(resource, operation), else: []),
      if(list?, do: sort_bindings(resource, operation, operation_name, pagination), else: []),
      include_bindings(resource, output)
    ])
  end

  ## Filters

  defp filter_bindings(_resource, %{filter: false}), do: []

  defp filter_bindings(resource, operation) do
    plural =
      resource
      |> AshSmithy.Resource.Info.plural_name()
      |> Macro.underscore()
      |> String.replace("_", " ")

    identifiers = AshSmithy.Resource.Info.identifiers(resource)

    resource
    |> structure_members()
    |> select_fields(resource, operation, :filter, &filterable?(resource, &1))
    |> Enum.flat_map(fn member ->
      field = Ash.Resource.Info.field(resource, member.name)
      descriptor = filter_descriptor(member.descriptor)
      operators? = Map.get(field, :filterable?) != :simple_equality
      name = member.member

      Enum.concat([
        [
          filter(
            member,
            :in,
            name,
            values_descriptor(resource, member, descriptor),
            "Only return #{plural} whose `#{name}` is one of the given values."
          )
        ],
        if operators? and comparable?(descriptor) do
          for {op, suffix, description} <- [
                {:greater_than, "Gt", "greater than"},
                {:greater_than_or_equal, "Gte", "greater than or equal to"},
                {:less_than, "Lt", "less than"},
                {:less_than_or_equal, "Lte", "less than or equal to"}
              ] do
            filter(
              member,
              op,
              name <> suffix,
              descriptor,
              "Only return #{plural} whose `#{name}` is #{description} the given value."
            )
          end
        else
          []
        end,
        if operators? and Ash.Type.get_type(field.type) in [Ash.Type.String, Ash.Type.CiString] and
             member.name not in identifiers do
          [
            filter(
              member,
              :contains,
              name <> "Contains",
              descriptor,
              "Only return #{plural} whose `#{name}` contains the given value."
            )
          ]
        else
          []
        end,
        if operators? and not member.required? do
          [
            filter(
              member,
              :is_nil,
              name <> "IsNil",
              {:simple, "Boolean", %{}},
              "Only return #{plural} whose `#{name}` is (`true`) or is not (`false`) null."
            )
          ]
        else
          []
        end
      ])
    end)
  end

  defp filter(member, op, name, descriptor, description) do
    %Binding{
      member: %Member{
        name: {member.name, op},
        member: name,
        descriptor: descriptor,
        description: description
      },
      source: :filter,
      location: :query,
      location_name: name,
      meta: {member.name, op}
    }
  end

  defp values_descriptor(resource, member, descriptor) do
    {:list, AshSmithy.Resource.Info.name(resource) <> Naming.shape_name(member.name) <> "Values",
     descriptor, false}
  end

  # Constraints describe valid values of the field, not valid values to filter by.
  defp filter_descriptor({:simple, type, traits}),
    do: {:simple, type, Map.take(traits, ["smithy.api#timestampFormat"])}

  defp filter_descriptor(descriptor), do: descriptor

  defp comparable?({:simple, type, _}), do: type in @comparable
  defp comparable?(_), do: false

  defp filterable?(resource, member) do
    field = Ash.Resource.Info.field(resource, member.name)

    scalar?(member.descriptor) and Map.get(field, :filterable?, true) != false and
      expression?(field)
  end

  ## Sorting

  defp sort_bindings(_resource, %{sort: false}, _operation_name, _pagination), do: []

  defp sort_bindings(resource, operation, operation_name, pagination) do
    pagination_type = if pagination, do: pagination.type, else: :offset

    resource
    |> structure_members()
    |> select_fields(resource, operation, :sort, fn member ->
      scalar?(member.descriptor) and
        Ash.Resource.Info.sortable?(resource, member.name, pagination_type: pagination_type)
    end)
    |> case do
      [] ->
        []

      members ->
        # Derived sorts are the same for every operation, so they can share a shape
        enum_name =
          if operation.sort == true do
            AshSmithy.Resource.Info.name(resource) <> "SortField"
          else
            operation_name <> "SortField"
          end

        values =
          Enum.flat_map(members, fn member ->
            name = enum_name(member.member)
            [{name <> "_ASC", member.member}, {name <> "_DESC", "-" <> member.member}]
          end)

        sorts =
          members
          |> Enum.flat_map(fn member ->
            [{member.member, {member.name, :asc}}, {"-" <> member.member, {member.name, :desc}}]
          end)
          |> Map.new()

        [
          %Binding{
            member: %Member{
              name: :sort,
              member: "sort",
              descriptor: {:list, enum_name <> "List", {:enum, enum_name, values}, false},
              description:
                "The fields to sort by, in order of precedence. Prefix a field with `-` to sort in descending order."
            },
            source: :sort,
            location: :query,
            location_name: "sort",
            meta: sorts
          }
        ]
    end
  end

  ## Includes

  defp include_bindings(resource, output) when output in [:record, :records] do
    case AshSmithy.Resource.Info.relationships(resource) do
      [] ->
        []

      relationships ->
        name = AshSmithy.Resource.Info.name(resource) <> "Include"

        members =
          Enum.map(relationships, fn relationship ->
            {AshSmithy.Resource.Info.member_name(resource, relationship.name), relationship.name}
          end)

        [
          %Binding{
            member: %Member{
              name: :include,
              member: "include",
              descriptor:
                {:list, name <> "List",
                 {:enum, name,
                  Enum.map(members, fn {member, _} -> {enum_name(member), member} end)}, false},
              description: "Related records to include in the response."
            },
            source: :include,
            location: :query,
            location_name: "include",
            meta: Map.new(members)
          }
        ]
    end
  end

  defp include_bindings(_resource, _output), do: []

  ## Helpers

  defp enum_name(member), do: member |> Macro.underscore() |> String.upcase()

  defp structure_members(resource) do
    {:structure, _, members} = AshSmithy.Type.resource_structure(resource)
    Enum.reject(members, &Ash.Resource.Info.relationship(resource, &1.name))
  end

  defp select_fields(members, resource, operation, option, default?) do
    case Map.fetch!(operation, option) do
      true ->
        Enum.filter(members, default?)

      fields ->
        Enum.map(fields, fn field ->
          member = Enum.find(members, &(&1.name == field))

          if is_nil(member) or not default?.(member) do
            raise Spark.Error.DslError,
              module: resource,
              path: [:smithy, :operations, operation.kind, operation.action, option],
              message:
                "#{inspect(field)} is not a #{if option == :filter, do: "filterable", else: "sortable"} field of the resource's structure"
          end

          member
        end)
    end
  end

  defp scalar?({:simple, type, _}), do: type not in ["Document", "Blob"]
  defp scalar?({:enum, _, _}), do: true
  defp scalar?(_), do: false

  # Calculations can only be filtered on if they can be expressed in the data layer.
  defp expression?(%Ash.Resource.Calculation{calculation: {module, _}}) do
    Code.ensure_compiled(module)
    function_exported?(module, :expression, 2)
  end

  defp expression?(_), do: true
end
