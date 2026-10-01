defmodule AshSmithy.Domain.Verifiers.VerifyOperations do
  @moduledoc false
  use Spark.Dsl.Verifier

  @impl true
  def verify(dsl) do
    domain = Spark.Dsl.Verifier.get_persisted(dsl, :module)

    dsl
    |> Ash.Domain.Info.resources()
    |> Enum.filter(&AshSmithy.Resource.Info.smithy_resource?/1)
    |> Enum.flat_map(fn resource ->
      resource
      |> AshSmithy.Resource.Info.operations()
      |> Enum.map(&{resource, AshSmithy.Plan.operation_name(resource, &1)})
    end)
    |> Enum.group_by(&elem(&1, 1), &elem(&1, 0))
    |> Enum.find(fn {_name, resources} -> Enum.count(resources) > 1 end)
    |> case do
      nil ->
        :ok

      {name, resources} ->
        {:error,
         Spark.Error.DslError.exception(
           module: domain,
           path: [:smithy],
           message:
             "Multiple operations are named #{name} (in #{Enum.map_join(Enum.uniq(resources), ", ", &inspect/1)}). " <>
               "Operation names must be unique within a service. Use the `name` option to rename one."
         )}
    end
  end
end
