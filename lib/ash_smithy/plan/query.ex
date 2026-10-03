defmodule AshSmithy.Plan.Query do
  @moduledoc false
  # Plans the query parameters derived from the resource rather than the action:
  # filters and sorts for operations that return lists, and includes for operations that
  # return records.
  #
  # Which fields can be filtered and sorted on, and with which operators and functions, comes
  # from the resource's `Ash.Info.Manifest`, which accounts for what the data layer supports.

  alias AshSmithy.Naming
  alias AshSmithy.Plan.Binding
  alias AshSmithy.Type.Member
  alias Ash.Info.Manifest

  @comparable ["Long", "Integer", "Double", "BigDecimal", "BigInteger", "Timestamp"]

  # Manifest operator => filter input operator, query parameter suffix, description
  @ranges [
    {:>, :greater_than, "Gt", "greater than"},
    {:>=, :greater_than_or_equal, "Gte", "greater than or equal to"},
    {:<, :less_than, "Lt", "less than"},
    {:<=, :less_than_or_equal, "Lte", "less than or equal to"}
  ]

  # Manifest function => query parameter suffix, description
  @string_functions [
    {:contains, "Contains", "contains"},
    {:string_starts_with, "StartsWith", "starts with"},
    {:string_ends_with, "EndsWith", "ends with"}
  ]

  def bindings(manifest, operation, action, operation_name, output, pagination) do
    list? = output == :records and action.type == :read

    Enum.concat([
      if(list?, do: filter_bindings(manifest, operation), else: []),
      if(list?, do: sort_bindings(manifest, operation, operation_name, pagination), else: []),
      include_bindings(manifest, output)
    ])
  end

  ## Filters

  defp filter_bindings(_manifest, %{filter: false}), do: []

  defp filter_bindings(manifest, operation) do
    resource = manifest.resource.module

    plural =
      resource
      |> AshSmithy.Resource.Info.plural_name()
      |> Macro.underscore()
      |> String.replace("_", " ")

    identifiers = AshSmithy.Resource.Info.identifiers(resource)

    resource
    |> structure_members()
    |> select_fields(resource, operation, :filter, &filterable?(manifest, &1))
    |> Enum.flat_map(fn member ->
      field = Manifest.Resource.get_field(manifest.resource, member.name)
      operators = MapSet.new(field.filter_operators || [], & &1.name)
      functions = MapSet.new(field.filter_functions || [], & &1.name)
      descriptor = filter_descriptor(member.descriptor)
      name = member.member

      Enum.concat([
        if MapSet.member?(operators, :in) or MapSet.member?(operators, :==) do
          [
            filter(
              member,
              :in,
              name,
              values_descriptor(resource, member, descriptor),
              "Only return #{plural} whose `#{name}` is one of the given values."
            )
          ]
        else
          []
        end,
        # Ash can compare any values, but ranges are only offered for numbers and timestamps
        for {operator, op, suffix, description} <- @ranges,
            comparable?(descriptor),
            MapSet.member?(operators, operator) do
          filter(
            member,
            op,
            name <> suffix,
            descriptor,
            "Only return #{plural} whose `#{name}` is #{description} the given value."
          )
        end,
        for {function, suffix, description} <- @string_functions,
            match?({:simple, "String", _}, descriptor),
            member.name not in identifiers,
            MapSet.member?(functions, function) do
          filter(
            member,
            function,
            name <> suffix,
            descriptor,
            "Only return #{plural} whose `#{name}` #{description} the given value."
          )
        end,
        if MapSet.member?(operators, :is_nil) and not member.required? do
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

  defp filterable?(manifest, member) do
    field = Manifest.Resource.get_field(manifest.resource, member.name)

    scalar?(member.descriptor) and field.filterable? == true and
      field.filter_operators not in [nil, []] and
      expression?(manifest.resource.module, field)
  end

  ## Sorting

  defp sort_bindings(_manifest, %{sort: false}, _operation_name, _pagination), do: []

  defp sort_bindings(manifest, operation, operation_name, pagination) do
    resource = manifest.resource.module
    keyset? = match?(%{type: :keyset}, pagination)

    resource
    |> structure_members()
    |> select_fields(resource, operation, :sort, fn member ->
      field = Manifest.Resource.get_field(manifest.resource, member.name)

      # Keyset pagination can't sort by calculations
      scalar?(member.descriptor) and field.sortable? == true and
        not (keyset? and field.kind == :calculation)
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

  defp include_bindings(manifest, output) when output in [:record, :records] do
    resource = manifest.resource.module

    case AshSmithy.Resource.Info.smithy_relationships!(resource) do
      [] ->
        []

      relationships ->
        name = AshSmithy.Resource.Info.name(resource) <> "Include"

        members =
          Enum.map(relationships, fn relationship ->
            {AshSmithy.Resource.Info.member_name(resource, relationship), relationship}
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

  defp include_bindings(_manifest, _output), do: []

  ## Helpers

  defp enum_name(member), do: member |> Macro.underscore() |> String.upcase()

  # The fields of the resource's structure, without its relationships
  defp structure_members(resource) do
    {:structure, _, members} = AshSmithy.Type.resource_structure(resource)
    relationships = AshSmithy.Resource.Info.smithy_relationships!(resource)
    Enum.reject(members, &(&1.name in relationships))
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

  # Calculations can only be filtered on if they can be expressed in the data layer, which
  # the manifest doesn't describe.
  defp expression?(resource, %{kind: :calculation, name: name}) do
    case Ash.Resource.Info.calculation(resource, name) do
      %{calculation: {module, _}} ->
        Code.ensure_compiled(module)
        function_exported?(module, :expression, 2)

      _ ->
        true
    end
  end

  defp expression?(_resource, _field), do: true
end
