defmodule AshSmithy.Resource.Verifiers.VerifyOperations do
  @moduledoc false
  use Spark.Dsl.Verifier

  alias Spark.Error.DslError

  @allowed_action_types %{
    create: [:create],
    read: [:read],
    update: [:update],
    delete: [:destroy],
    list: [:read],
    operation: [:read, :update, :destroy],
    collection_operation: [:create, :read, :action]
  }

  @lifecycle [:create, :read, :update, :delete, :list]

  @impl true
  def verify(dsl) do
    resource = Spark.Dsl.Verifier.get_persisted(dsl, :module)
    operations = AshSmithy.Resource.Info.operations(dsl)

    with :ok <- verify_identifiers(dsl, resource),
         :ok <- verify_fields(dsl, resource),
         :ok <- verify_relationships(dsl, resource),
         :ok <- verify_unique_lifecycle(operations, resource) do
      Enum.reduce_while(operations, :ok, fn operation, :ok ->
        case verify_operation(dsl, resource, operation) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    end
  end

  defp verify_identifiers(dsl, resource) do
    identifiers = AshSmithy.Resource.Info.identifiers(dsl)

    cond do
      identifiers == [] ->
        {:error,
         DslError.exception(
           module: resource,
           path: [:smithy, :identifiers],
           message: "Smithy resources must have at least one identifier"
         )}

      missing = Enum.find(identifiers, &is_nil(Ash.Resource.Info.public_attribute(dsl, &1))) ->
        {:error,
         DslError.exception(
           module: resource,
           path: [:smithy, :identifiers],
           message: "Identifier #{inspect(missing)} must be a public attribute"
         )}

      true ->
        :ok
    end
  end

  defp verify_fields(dsl, resource) do
    case Enum.find(
           AshSmithy.Resource.Info.fields(dsl),
           &is_nil(Ash.Resource.Info.public_field(dsl, &1))
         ) do
      nil ->
        :ok

      field ->
        {:error,
         DslError.exception(
           module: resource,
           path: [:smithy, :fields],
           message: "Field #{inspect(field)} must be a public attribute, calculation or aggregate"
         )}
    end
  end

  defp verify_relationships(dsl, resource) do
    case Enum.find(
           AshSmithy.Resource.Info.smithy_relationships!(dsl),
           &is_nil(Ash.Resource.Info.public_relationship(dsl, &1))
         ) do
      nil ->
        :ok

      relationship ->
        {:error,
         DslError.exception(
           module: resource,
           path: [:smithy, :relationships],
           message: "Relationship #{inspect(relationship)} must be a public relationship"
         )}
    end
  end

  defp verify_unique_lifecycle(operations, resource) do
    operations
    |> Enum.filter(&(&1.kind in @lifecycle))
    |> Enum.group_by(& &1.kind)
    |> Enum.find(fn {_kind, ops} -> Enum.count(ops) > 1 end)
    |> case do
      nil ->
        :ok

      {kind, _} ->
        {:error,
         DslError.exception(
           module: resource,
           path: [:smithy, :operations, kind],
           message: "Only one `#{kind}` operation may be defined per resource"
         )}
    end
  end

  defp verify_operation(dsl, resource, operation) do
    action = Ash.Resource.Info.action(dsl, operation.action)
    path = [:smithy, :operations, operation.kind, operation.action]
    allowed = Map.fetch!(@allowed_action_types, operation.kind)

    cond do
      is_nil(action) ->
        {:error,
         DslError.exception(
           module: resource,
           path: path,
           message: "No such action #{inspect(operation.action)}"
         )}

      action.type not in allowed ->
        {:error,
         DslError.exception(
           module: resource,
           path: path,
           message:
             "`#{operation.kind}` operations require an action of type #{Enum.map_join(allowed, " or ", &inspect/1)}, " <>
               "but #{inspect(operation.action)} is a #{inspect(action.type)} action"
         )}

      Map.get(action, :public?, true) == false ->
        {:error,
         DslError.exception(
           module: resource,
           path: path,
           message:
             "Action #{inspect(operation.action)} is not public. Only public actions can be exposed over Smithy."
         )}

      operation.kind == :list and operation.paginated? and
          !(action.pagination && (action.pagination.keyset? || action.pagination.offset?)) ->
        {:error,
         DslError.exception(
           module: resource,
           path: path,
           message:
             "Action #{inspect(operation.action)} does not support pagination. " <>
               "Add pagination to the action, or set `paginated?: false`."
         )}

      operation.read_action &&
          !match?(%{type: :read}, Ash.Resource.Info.action(dsl, operation.read_action)) ->
        {:error,
         DslError.exception(
           module: resource,
           path: path,
           message: "No such read action #{inspect(operation.read_action)}"
         )}

      true ->
        verify_bindings(dsl, resource, operation, action, path)
    end
  end

  defp verify_bindings(dsl, resource, operation, action, path) do
    inputs = action_inputs(dsl, action)

    (List.wrap(operation.query) ++ Keyword.keys(operation.headers))
    |> Enum.find(&(&1 not in inputs))
    |> case do
      nil ->
        :ok

      input ->
        {:error,
         DslError.exception(
           module: resource,
           path: path,
           message:
             "#{inspect(input)} is bound to the query string or a header, but it is not an input of #{inspect(action.name)}"
         )}
    end
  end

  defp action_inputs(_dsl, action) do
    Enum.map(action.arguments, & &1.name) ++ List.wrap(Map.get(action, :accept))
  end
end
