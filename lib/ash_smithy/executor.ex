defmodule AshSmithy.Executor do
  @moduledoc """
  Runs planned operations against Ash. Protocol independent: receives already decoded input
  and returns Elixir values for the protocol to serialize.
  """

  alias AshSmithy.Plan.Operation

  @doc """
  Runs an operation, returning the values of its output members.

  `input` is a list of `{binding, value}` pairs for each input member that was provided.
  """
  @spec run(Plug.Conn.t(), Ash.Domain.t(), Operation.t(), [{AshSmithy.Plan.Binding.t(), term}]) ::
          {:ok, map} | {:error, term}
  def run(conn, domain, %Operation{} = operation, input) do
    params =
      Enum.reduce(input, %{}, fn {binding, value}, params ->
        Map.update(
          params,
          binding.source,
          %{binding.member.name => value},
          &Map.put(&1, binding.member.name, value)
        )
      end)

    with {:ok, result} <- execute(conn, domain, operation, params) do
      {:ok, output(operation, result)}
    end
  end

  @doc """
  Builds the values of an operation's output members from the result of its action.
  """
  @spec output(Operation.t(), term) :: map
  def output(%Operation{output: :record}, record) do
    %{record: record, metadata: record.__metadata__}
  end

  def output(%Operation{output: :records} = operation, {records, next_token}) do
    items =
      if operation.metadata do
        Enum.map(records, &%{record: &1, metadata: &1.__metadata__})
      else
        records
      end

    %{items: items, next_token: next_token}
  end

  def output(%Operation{output: :result}, result), do: %{result: result}
  def output(%Operation{output: :empty}, nil), do: %{}
  def output(%Operation{output: :empty}, record), do: %{metadata: record.__metadata__}

  defp execute(conn, domain, %Operation{} = operation, params) do
    opts = ash_opts(conn, domain)
    input = Map.get(params, :input, %{})
    identifiers = Map.get(params, :identifier, %{})

    case {operation.action_type, operation.read_action} do
      {:create, _} ->
        operation.resource
        |> Ash.Changeset.for_create(operation.action, input, opts)
        |> Ash.create(Keyword.put(opts, :load, loads(operation, params)))

      {:read, _} when operation.output == :records ->
        read_many(operation, input, params, opts)

      {:read, _} ->
        operation.resource
        |> Ash.Query.for_read(operation.action, input, opts)
        |> Ash.Query.load(loads(operation, params))
        |> filter_identifiers(operation.resource, identifiers)
        |> read_one(opts)

      {:update, read_action} ->
        with {:ok, record} <- fetch(operation, read_action, identifiers, opts) do
          record
          |> Ash.Changeset.for_update(operation.action, input, opts)
          |> Ash.update(Keyword.put(opts, :load, loads(operation, params)))
        end

      {:destroy, read_action} ->
        with {:ok, record} <- fetch(operation, read_action, identifiers, opts) do
          # The destroyed record is only needed to return its action metadata
          return_destroyed? = not is_nil(operation.metadata)

          record
          |> Ash.Changeset.for_destroy(operation.action, input, opts)
          |> Ash.destroy(Keyword.put(opts, :return_destroyed?, return_destroyed?))
          |> case do
            :ok -> {:ok, nil}
            {:ok, record} -> {:ok, record}
            {:error, error} -> {:error, error}
          end
        end

      {:action, _} ->
        operation.resource
        |> Ash.ActionInput.for_action(operation.action, input, opts)
        |> Ash.run_action(opts)
        |> case do
          :ok -> {:ok, nil}
          other -> other
        end
    end
  end

  defp ash_opts(conn, domain) do
    [
      domain: domain,
      actor: Ash.PlugHelpers.get_actor(conn),
      tenant: Ash.PlugHelpers.get_tenant(conn),
      context: Ash.PlugHelpers.get_context(conn) || %{}
    ]
  end

  defp fetch(operation, read_action, identifiers, opts) do
    operation.resource
    |> Ash.Query.for_read(read_action, %{}, opts)
    |> filter_identifiers(operation.resource, identifiers)
    |> read_one(opts)
  end

  defp read_one({:error, error}, _opts), do: {:error, error}

  defp read_one(query, opts) do
    case Ash.read_one(query, opts) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, record} -> {:ok, record}
      {:error, error} -> {:error, error}
    end
  end

  # Identifiers that can't be cast can't match any record.
  defp filter_identifiers(query, resource, identifiers) do
    Enum.reduce_while(identifiers, query, fn {name, value}, query ->
      attribute = Ash.Resource.Info.attribute(resource, name)

      case Ash.Type.cast_input(attribute.type, value, attribute.constraints) do
        {:ok, value} when not is_nil(value) ->
          {:cont, Ash.Query.do_filter(query, [{name, value}])}

        _ ->
          {:halt, {:error, :not_found}}
      end
    end)
  end

  defp read_many(operation, input, params, opts) do
    query =
      operation.resource
      |> Ash.Query.for_read(operation.action, input, opts)
      |> Ash.Query.load(loads(operation, params))
      |> filter_and_sort(operation, params)

    case operation.pagination do
      nil ->
        page_opts =
          case Ash.Resource.Info.action(operation.resource, operation.action) do
            %{pagination: %{}} -> [page: false]
            _ -> []
          end

        with {:ok, records} <- Ash.read(query, Keyword.merge(opts, page_opts)) do
          {:ok, {records, nil}}
        end

      pagination ->
        page = Map.get(params, :page_token, %{})
        size = Map.get(params, :page_size, %{})
        limit = size[:max_results] || pagination.default_limit

        with {:ok, page_opts} <- page_opts(pagination.type, page[:next_token], limit),
             {:ok, result} <- Ash.read(query, Keyword.put(opts, :page, page_opts)) do
          case result do
            # Ash doesn't paginate when no limit is given and pagination isn't required
            records when is_list(records) -> {:ok, {records, nil}}
            page -> {:ok, {page.results, next_token(pagination.type, page, page_opts)}}
          end
        end
    end
  end

  defp page_opts(type, token, limit) do
    base = if limit, do: [limit: limit], else: []

    case {type, token} do
      {_, nil} ->
        {:ok, base}

      {:keyset, token} ->
        {:ok, Keyword.put(base, :after, token)}

      {:offset, token} ->
        with {:ok, "offset:" <> offset} <- Base.url_decode64(token, padding: false),
             {offset, ""} <- Integer.parse(offset) do
          {:ok, Keyword.put(base, :offset, offset)}
        else
          _ -> {:error, {:validation, [{"/nextToken", "is not a valid pagination token"}]}}
        end
    end
  end

  defp next_token(_type, %{more?: false}, _page_opts), do: nil

  defp next_token(:keyset, %{results: results}, _page_opts) do
    case List.last(results) do
      nil -> nil
      record -> record.__metadata__[:keyset]
    end
  end

  defp next_token(:offset, page, page_opts) do
    offset = (page_opts[:offset] || 0) + Enum.count(page.results)
    Base.url_encode64("offset:#{offset}", padding: false)
  end

  # Calculations and aggregates in the resource's structure, plus any included relationships
  # (along with the calculations and aggregates of their structures).
  defp loads(operation, params) do
    includes =
      params
      |> Map.get(:include, %{})
      |> Map.get(:include, [])
      |> Enum.uniq()
      |> Enum.map(fn member ->
        relationship =
          Ash.Info.Manifest.Resource.get_relationship(
            AshSmithy.Manifest.for_resource(operation.resource).resource,
            include_meta(operation)[member]
          )

        {relationship.name, loads(relationship.destination)}
      end)

    loads(operation.resource) ++ includes
  end

  defp loads(resource) do
    definition = AshSmithy.Manifest.for_resource(resource).resource

    resource
    |> AshSmithy.Type.resource_structure()
    |> elem(2)
    |> Enum.filter(fn member ->
      match?(
        %{kind: kind} when kind in [:calculation, :aggregate],
        Ash.Info.Manifest.Resource.get_field(definition, member.name)
      )
    end)
    |> Enum.map(& &1.name)
  end

  defp include_meta(operation) do
    Enum.find_value(operation.input, %{}, fn
      %{source: :include, meta: meta} -> meta
      _ -> nil
    end)
  end

  defp filter_and_sort(query, operation, params) do
    query =
      params
      |> Map.get(:filter, %{})
      |> Enum.reduce(query, fn {{field, op}, value}, query ->
        Ash.Query.filter_input(query, %{field => %{op => value}})
      end)

    case params |> Map.get(:sort, %{}) |> Map.get(:sort) do
      nil ->
        query

      sorts ->
        sort_meta =
          Enum.find_value(operation.input, %{}, fn
            %{source: :sort, meta: meta} -> meta
            _ -> nil
          end)

        Ash.Query.sort_input(query, Enum.map(sorts, &Map.fetch!(sort_meta, &1)), prepend?: true)
    end
  end
end
