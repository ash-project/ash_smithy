defmodule AshSmithy.Protocols.RestJson1 do
  @moduledoc """
  Server implementation of the [`aws.protocols#restJson1`](https://smithy.io/2.0/aws/protocols/aws-restjson1-protocol.html)
  protocol.

  The implementation is driven entirely by an `AshSmithy.Plan.Operation`'s input and output
  bindings, and is independent of Ash: the operation is run by a function given to `handle/4`.
  """

  require Logger

  alias AshSmithy.Codec
  alias AshSmithy.Plan.Operation
  alias AshSmithy.Validation

  @doc """
  Handles a request for an operation.

  `run` receives the decoded and validated input as a list of `{binding, value}` pairs, and must
  return `{:ok, output}` where output is a map of output member name to value, or `{:error, error}`.
  """
  @spec handle(Plug.Conn.t(), Operation.t(), map, ([{term, term}] -> {:ok, map} | {:error, term})) ::
          Plug.Conn.t()
  def handle(conn, %Operation{} = operation, labels, run) do
    with :ok <- check_accept(conn, operation),
         {:ok, conn, body} <- read_body(conn, operation),
         {:ok, input} <- decode_input(conn, operation, labels, body),
         :ok <- validate(operation, input),
         {:ok, output} <- run.(input) do
      send_output(conn, operation, output)
    else
      {:error, error} -> send_error(conn, operation, error)
    end
  end

  @doc false
  def unknown_operation(conn) do
    send_error_response(
      conn,
      "UnknownOperationException",
      404,
      %{"message" => "No operation matches #{conn.method} #{conn.request_path}"}
    )
  end

  ## Content negotiation

  # Operations with no input (`smithy.api#Unit`) have `nil` input.
  defp body_input?(operation), do: Enum.any?(operation.input || [], &(&1.location == :body))

  # Operations with no output (`smithy.api#Unit`) have `nil` output members.
  defp body_output?(operation), do: is_list(operation.output_members)

  defp check_accept(conn, operation) do
    case Plug.Conn.get_req_header(conn, "accept") do
      [] ->
        :ok

      values ->
        acceptable? =
          values
          |> Enum.flat_map(&String.split(&1, ","))
          |> Enum.map(&media_type/1)
          |> Enum.any?(&(&1 in ["application/json", "application/*", "*/*"]))

        if acceptable? or not body_output?(operation), do: :ok, else: {:error, :not_acceptable}
    end
  end

  defp media_type(value) do
    value |> String.split(";") |> hd() |> String.trim() |> String.downcase()
  end

  ## Input

  defp read_body(conn, operation) do
    with {:ok, conn, body} <- raw_body(conn) do
      content_type =
        case Plug.Conn.get_req_header(conn, "content-type") do
          [] -> nil
          [value | _] -> media_type(value)
        end

      empty? = String.trim(body) == ""

      cond do
        body_input?(operation) and not empty? and content_type != "application/json" ->
          {:error, :unsupported_media_type}

        body_input?(operation) and content_type not in [nil, "application/json"] ->
          {:error, :unsupported_media_type}

        # Without modeled body input a body can't be sent, although an empty input structure
        # accepts an empty JSON object
        not body_input?(operation) and content_type != nil and not empty? and
            not (operation.input == [] and content_type == "application/json") ->
          {:error, :unsupported_media_type}

        empty? or not body_input?(operation) ->
          {:ok, conn, %{}}

        true ->
          case Jason.decode(body, floats: :decimals) do
            {:ok, decoded} when is_map(decoded) -> {:ok, conn, decoded}
            {:ok, _} -> {:error, {:serialization, "The request body must be a JSON object"}}
            {:error, _} -> {:error, {:serialization, "The request body is not valid JSON"}}
          end
      end
    end
  end

  # The body may already have been parsed, e.g. by `Plug.Parsers` in a Phoenix pipeline.
  defp raw_body(conn) do
    case conn.body_params do
      %Plug.Conn.Unfetched{} -> do_read_body(conn, "")
      params when is_map(params) and map_size(params) > 0 -> {:ok, conn, Jason.encode!(params)}
      _ -> do_read_body(conn, "")
    end
  end

  defp do_read_body(conn, acc) do
    case Plug.Conn.read_body(conn) do
      {:ok, body, conn} -> {:ok, conn, acc <> body}
      {:more, body, conn} -> do_read_body(conn, acc <> body)
      {:error, _} -> {:error, {:serialization, "Could not read the request body"}}
    end
  end

  defp decode_input(conn, operation, labels, body) do
    query = query_params(conn)

    (operation.input || [])
    |> Enum.reduce_while({:ok, []}, fn binding, {:ok, acc} ->
      member = binding.member
      traits = member.traits || %{}

      raw =
        case binding.location do
          :label -> Map.fetch(labels, binding.location_name)
          :query -> Map.fetch(query, binding.location_name)
          :header -> fetch_header(conn, binding.location_name)
          :body -> body |> Map.fetch(Codec.json_name(member)) |> reject_nil()
          :query_params -> query_params_map(query, operation)
          :prefix_headers -> prefix_headers_map(conn, binding.location_name)
        end

      decoded =
        case {raw, binding.location} do
          {:error, _} ->
            default(member)

          {{:ok, value}, :body} ->
            Codec.decode(member.descriptor, value, traits)

          {{:ok, values}, :query_params} ->
            decode_string_map(member.descriptor, values, :query)

          {{:ok, values}, :prefix_headers} ->
            decode_string_map(member.descriptor, values, :header)

          {{:ok, value}, location} ->
            Codec.decode_string(member.descriptor, value, location, traits)
        end

      case decoded do
        :missing -> {:cont, {:ok, acc}}
        {:ok, value} -> {:cont, {:ok, [{binding, value} | acc]}}
        {:error, message} -> {:halt, {:error, {:serialization, "#{member.member}: #{message}"}}}
      end
    end)
    |> case do
      {:ok, input} -> {:ok, Enum.reverse(input)}
      error -> error
    end
  end

  # Servers bind every query parameter to `@httpQueryParams`, including those that are also
  # bound to `@httpQuery` members.
  defp query_params_map(query, _operation) do
    if query == %{}, do: :error, else: {:ok, query}
  end

  # `@httpPrefixHeaders` binds the headers starting with the prefix, keyed by the rest of the name.
  defp prefix_headers_map(conn, prefix) do
    prefix = String.downcase(prefix)

    conn.req_headers
    |> Enum.filter(fn {name, _} -> String.starts_with?(name, prefix) end)
    |> Enum.map(fn {name, value} -> {String.replace_prefix(name, prefix, ""), value} end)
    |> case do
      [] -> :error
      headers -> {:ok, Map.new(headers)}
    end
  end

  defp decode_string_map(descriptor, values, location) do
    {:map, _, _, value_descriptor, _} = Codec.unwrap(descriptor)

    Enum.reduce_while(values, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      # Query parameter maps may bind lists of values, or only the first value
      value =
        case {Codec.unwrap(value_descriptor), value} do
          {{:list, _, _, _}, value} -> value
          {_, [value | _]} -> value
          {_, value} -> value
        end

      case Codec.decode_string(value_descriptor, value, location) do
        {:ok, decoded} -> {:cont, {:ok, Map.put(acc, key, decoded)}}
        {:error, message} -> {:halt, {:error, "#{key}: #{message}"}}
      end
    end)
  end

  defp reject_nil({:ok, nil}), do: :error
  defp reject_nil(other), do: other

  # Servers populate members that have defaults when they are missing from the request.
  defp default(member) do
    case Codec.default(member) do
      {:ok, value} -> {:ok, value}
      :error -> :missing
    end
  end

  defp query_params(conn) do
    conn.query_string
    |> String.split("&", trim: true)
    |> Enum.reduce(%{}, fn pair, acc ->
      {key, value} =
        case String.split(pair, "=", parts: 2) do
          [key, value] -> {URI.decode(key), URI.decode(value)}
          [key] -> {URI.decode(key), ""}
        end

      Map.update(acc, key, [value], &(&1 ++ [value]))
    end)
  end

  defp fetch_header(conn, name) do
    case Plug.Conn.get_req_header(conn, String.downcase(name)) do
      [] -> :error
      values -> {:ok, Enum.join(values, ", ")}
    end
  end

  defp validate(operation, input) do
    values = Map.new(input, fn {binding, value} -> {binding.member.name, value} end)

    case Validation.validate_members(Enum.map(operation.input || [], & &1.member), values) do
      [] -> :ok
      errors -> {:error, {:validation, errors}}
    end
  end

  ## Output

  @doc false
  def send_output(conn, operation, output) do
    case operation.output_members do
      nil ->
        Plug.Conn.send_resp(conn, operation.code, "")

      members ->
        {conn, status, body} = encode_members(conn, members, output, operation.code)
        send_json(conn, status, body)
    end
  end

  defp encode_members(conn, members, value, status) do
    Enum.reduce(members, {conn, status, %{}}, fn binding, {conn, status, body} ->
      member = binding.member
      traits = member.traits || %{}
      field = value |> Codec.fetch_field_or_default(member) |> ok_or_nil()

      case binding.location do
        :header ->
          case Codec.encode_header(member.descriptor, field, traits) do
            nil ->
              {conn, status, body}

            encoded ->
              {Plug.Conn.put_resp_header(conn, String.downcase(binding.location_name), encoded),
               status, body}
          end

        :response_code ->
          {conn, field || status, body}

        :prefix_headers ->
          {:map, _, _, value_descriptor, _} = Codec.unwrap(member.descriptor)

          conn =
            Enum.reduce(field || %{}, conn, fn {key, value}, conn ->
              case Codec.encode_header(value_descriptor, value, %{}) do
                nil ->
                  conn

                encoded ->
                  Plug.Conn.put_resp_header(
                    conn,
                    String.downcase(binding.location_name <> key),
                    encoded
                  )
              end
            end)

          {conn, status, body}

        _body ->
          case Codec.encode(member.descriptor, field, traits) do
            nil -> {conn, status, body}
            encoded -> {conn, status, Map.put(body, Codec.json_name(member), encoded)}
          end
      end
    end)
  end

  defp ok_or_nil({:ok, value}), do: value
  defp ok_or_nil(:error), do: nil

  defp send_json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json", nil)
    |> Plug.Conn.send_resp(status, Jason.encode_to_iodata!(body))
  end

  ## Errors

  @doc """
  Sends a modeled error. `members` are the bindings of the error structure's members, and
  `value` a map of member name to value.
  """
  def send_modeled_error(conn, name, status, members, value) do
    {conn, _status, body} = encode_members(conn, members, value, status)
    send_error_response(conn, name, status, body)
  end

  defp send_error(conn, operation, error) do
    {type, status, body} = error_response(operation, error)
    send_error_response(conn, type, status, body)
  end

  defp send_error_response(conn, type, status, body) do
    conn
    |> Plug.Conn.put_resp_header("x-amzn-errortype", type)
    |> send_json(status, body)
  end

  defp error_response(_operation, {:serialization, message}) do
    {"SerializationException", 400, %{"message" => message}}
  end

  defp error_response(_operation, {:validation, errors}) do
    {"ValidationException", 400,
     %{
       "message" => Validation.message(errors),
       "fieldList" =>
         Enum.map(errors, fn {path, message} -> %{"path" => path, "message" => message} end)
     }}
  end

  defp error_response(_operation, :unsupported_media_type) do
    {"UnsupportedMediaTypeException", 415, %{"message" => "Unsupported media type"}}
  end

  defp error_response(_operation, :not_acceptable) do
    {"NotAcceptableException", 406, %{"message" => "Not acceptable"}}
  end

  defp error_response(_operation, :not_found) do
    {"NotFoundException", 404, %{"message" => "The requested resource could not be found."}}
  end

  defp error_response(operation, error) do
    case Ash.Error.to_error_class(error) do
      %Ash.Error.Forbidden{} ->
        {"ForbiddenException", 403, %{"message" => "Forbidden"}}

      %Ash.Error.Invalid{errors: errors} ->
        if Enum.any?(errors, &match?(%Ash.Error.Query.NotFound{}, &1)) and
             "NotFoundException" in operation.errors do
          error_response(operation, :not_found)
        else
          error_response(operation, {:validation, Enum.map(errors, &field_error(operation, &1))})
        end

      error ->
        Logger.error(
          "Unhandled error in #{operation.name}: " <> Exception.format(:error, error, [])
        )

        {"InternalServerError", 500, %{"message" => "An internal error occurred."}}
    end
  end

  defp field_error(operation, error) do
    field =
      case error do
        %{field: field} when not is_nil(field) -> field
        %{fields: [field | _]} -> field
        _ -> nil
      end

    path =
      case field do
        nil ->
          "/"

        field ->
          member =
            Enum.find_value(operation.input, fn binding ->
              if binding.member.name == field, do: binding.member.member
            end) || AshSmithy.Resource.Info.member_name(operation.resource, field)

          "/" <> member
      end

    {path, error_message(error)}
  end

  defp error_message(%{message: message, vars: vars} = error) when is_binary(message) do
    vars = if is_list(vars) or is_map(vars), do: vars, else: []

    Enum.reduce(vars, message, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", to_string_safe(value))
    end)
  rescue
    _ -> Exception.message(error)
  end

  defp error_message(error), do: Exception.message(error)

  defp to_string_safe(value) do
    if String.Chars.impl_for(value), do: to_string(value), else: inspect(value)
  end
end
