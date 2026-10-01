defmodule AshSmithy.Router do
  @moduledoc """
  A Plug that serves the operations of one or more `AshSmithy.Domain` domains using the
  domain's Smithy protocol.

  ```elixir
  defmodule MyAppWeb.SmithyRouter do
    use AshSmithy.Router,
      domains: [MyApp.Helpdesk],
      # optional, serves the Smithy JSON AST of the domains at this path
      model: "/model.json"
  end
  ```

  Then forward to it, e.g. in a Phoenix router:

  ```elixir
  forward "/api", MyAppWeb.SmithyRouter
  ```

  Operation URIs are matched relative to where the router is mounted.

  The actor, tenant and context are taken from the conn, as set by
  `Ash.PlugHelpers.set_actor/2`, `Ash.PlugHelpers.set_tenant/2` and
  `Ash.PlugHelpers.set_context/2`.

  ## Options

    * `:domains` - the domains to serve. Required.
    * `:model` - a path at which to serve the Smithy JSON AST for the domains.
    * `:before_dispatch` - an `{module, function, args}` called with the conn and the matched
      `AshSmithy.Plan.Operation` before it is executed. Must return a conn. If the returned conn
      is halted, the operation is not executed.
  """

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      @behaviour Plug

      @ash_smithy_domains List.wrap(opts[:domains] || opts[:domain])

      for domain <- @ash_smithy_domains do
        Code.ensure_compiled!(domain)
      end

      @ash_smithy_routes AshSmithy.Router.routes(@ash_smithy_domains)
      @ash_smithy_opts Keyword.drop(opts, [:domain, :domains])

      @doc false
      def domains, do: @ash_smithy_domains

      @doc false
      def routes, do: @ash_smithy_routes

      @impl Plug
      def init(opts), do: opts

      @impl Plug
      def call(conn, _opts) do
        AshSmithy.Router.call(conn, __MODULE__, @ash_smithy_routes, @ash_smithy_opts)
      end
    end
  end

  @doc false
  def routes(domains) do
    domains
    |> Enum.flat_map(fn domain ->
      domain
      |> AshSmithy.Plan.service()
      |> Map.fetch!(:operations)
      |> Enum.map(&route(&1, domain))
    end)
    |> sort_routes()
  end

  @doc false
  # A route for an operation. `context` is passed back when the route matches.
  def route(operation, context) do
    {path, query} =
      case String.split(operation.uri, "?", parts: 2) do
        [path, query] -> {path, query}
        [path] -> {path, ""}
      end

    segments =
      path
      |> String.split("/", trim: true)
      |> Enum.map(fn segment ->
        cond do
          String.match?(segment, ~r/^\{.+\+\}$/) -> {:greedy, String.slice(segment, 1..-3//1)}
          String.match?(segment, ~r/^\{.+\}$/) -> {:label, String.slice(segment, 1..-2//1)}
          true -> {:literal, segment}
        end
      end)

    # Query string literals in the URI must be present for the route to match
    query =
      query
      |> String.split("&", trim: true)
      |> Enum.map(fn pair ->
        case String.split(pair, "=", parts: 2) do
          [key, value] -> {key, value}
          [key] -> {key, nil}
        end
      end)

    %{
      method: operation.method,
      segments: segments,
      query: query,
      operation: operation,
      context: context
    }
  end

  @doc false
  # Literal segments are preferred over labels, labels over greedy labels, and routes with
  # more query literals are preferred, so that e.g. `/tickets/search` wins over `/tickets/{id}`.
  def sort_routes(routes) do
    Enum.sort_by(routes, fn route ->
      {Enum.map(route.segments, fn
         {:literal, _} -> 0
         {:label, _} -> 1
         {:greedy, _} -> 2
       end), -length(route.query)}
    end)
  end

  @doc false
  def call(conn, router, routes, opts) do
    if opts[:model] && conn.method == "GET" &&
         conn.path_info == String.split(opts[:model], "/", trim: true) do
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, AshSmithy.Model.to_json(router.domains()))
    else
      case match(routes, conn) do
        {:ok, %{operation: operation, context: domain}, labels} ->
          conn
          |> before_dispatch(operation, opts)
          |> then(fn conn ->
            if conn.halted do
              conn
            else
              AshSmithy.Protocols.RestJson1.handle(conn, operation, labels, fn input ->
                AshSmithy.Executor.run(conn, domain, operation, input)
              end)
            end
          end)

        :error ->
          AshSmithy.Protocols.RestJson1.unknown_operation(conn)
      end
    end
  end

  defp before_dispatch(conn, operation, opts) do
    case opts[:before_dispatch] do
      {module, function, args} -> apply(module, function, [conn, operation | args])
      nil -> conn
    end
  end

  @doc false
  def match(routes, conn) do
    query =
      conn.query_string
      |> String.split("&", trim: true)
      |> Enum.map(fn pair ->
        case String.split(pair, "=", parts: 2) do
          [key, value] -> {URI.decode(key), URI.decode(value)}
          [key] -> {URI.decode(key), ""}
        end
      end)

    path_info = conn.path_info

    Enum.find_value(routes, :error, fn route ->
      with true <- route.method == conn.method,
           true <- Enum.all?(route.query, &query_literal_present?(&1, query)),
           {:ok, labels} <- match_segments(route.segments, path_info, %{}) do
        {:ok, route, labels}
      else
        _ -> nil
      end
    end)
  end

  defp query_literal_present?({key, nil}, query), do: List.keymember?(query, key, 0)
  defp query_literal_present?({key, value}, query), do: {key, value} in query

  defp match_segments([], [], labels), do: {:ok, labels}

  # Greedy labels match one or more segments
  defp match_segments([{:greedy, name} | segments], path, labels) do
    min_rest = length(segments)

    1..max(length(path) - min_rest, 0)//1
    |> Enum.find_value(:error, fn count ->
      {consumed, rest} = Enum.split(path, count)

      case match_segments(segments, rest, labels) do
        {:ok, labels} -> {:ok, Map.put(labels, name, Enum.map_join(consumed, "/", &URI.decode/1))}
        :error -> nil
      end
    end)
  end

  defp match_segments([{:literal, literal} | segments], [segment | rest], labels) do
    if URI.decode(segment) == literal or segment == literal do
      match_segments(segments, rest, labels)
    else
      :error
    end
  end

  defp match_segments([{:label, name} | segments], [value | rest], labels) when value != "" do
    match_segments(segments, rest, Map.put(labels, name, URI.decode(value)))
  end

  defp match_segments(_, _, _), do: :error
end
