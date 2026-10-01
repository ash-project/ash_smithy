defmodule AshSmithy.ConformanceTest do
  @moduledoc """
  Runs the Smithy protocol compliance tests for `aws.protocols#restJson1` against the server.

  Requires the Smithy CLI (set `SMITHY_CLI`, or have `smithy` on the path) to fetch the
  `smithy-aws-protocol-tests` model. Test cases that rely on protocol features ash_smithy
  never generates (e.g. `@httpPayload`) are skipped.
  """
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  alias AshSmithy.Protocols.RestJson1
  alias AshSmithy.Test.Conformance

  @moduletag :conformance

  if File.exists?(Conformance.ast_path()) do
    for test_case <- Conformance.cases() do
      unsupported =
        case test_case.kind do
          :error ->
            {_, _, _, unsupported} = Conformance.error(test_case.shape)
            unsupported

          _ ->
            {_, unsupported} = Conformance.operation(test_case.shape)
            unsupported
        end

      if unsupported != [] do
        @tag skip: "uses #{Enum.join(unsupported, ", ")}, which ash_smithy does not generate"
      end

      @test_case test_case
      test "#{test_case.kind} #{test_case.id}" do
        run(@test_case)
      end
    end
  else
    @tag skip: "Smithy CLI not found, set SMITHY_CLI to run the protocol compliance tests"
    test "protocol compliance tests" do
    end
  end

  defp run(%{kind: :request, case: test} = test_case) do
    {operation, _} = Conformance.operation(test_case.shape)
    conn = build_request(test)
    labels = route!(test_case, conn)

    response =
      RestJson1.handle(conn, operation, labels, fn input ->
        send(self(), {:input, input})
        {:ok, %{}}
      end)

    assert_received {:input, input},
                    "request was rejected with #{response.status}: #{response.resp_body}"

    bindings = operation.input || []
    descriptor = {:structure, "Input", Enum.map(bindings, & &1.member)}

    actual =
      Conformance.to_node(
        descriptor,
        Map.new(input, fn {binding, value} -> {binding.member.name, value} end)
      )

    # Query strings and headers can't distinguish an empty list from an absent one
    expected =
      descriptor
      |> Conformance.normalize(test["params"] || %{})
      |> Map.reject(fn {member, value} ->
        value == [] and not Map.has_key?(actual, member) and
          Enum.any?(bindings, &(&1.member.member == member and &1.location in [:query, :header]))
      end)

    assert Conformance.node_equal?(actual, expected),
           "params did not match.\n\nexpected: #{inspect(expected)}\n\nactual:   #{inspect(actual)}"
  end

  defp run(%{kind: :response, case: test} = test_case) do
    {operation, _} = Conformance.operation(test_case.shape)

    value =
      AshSmithy.Codec.from_node(
        {:structure, "Output", Enum.map(operation.output_members || [], & &1.member)},
        test["params"] || %{}
      )

    conn = RestJson1.send_output(conn(:get, "/"), operation, value)
    assert_response(conn, test["code"], test)
  end

  defp run(%{kind: :error, case: test} = test_case) do
    {name, status, members, _} = Conformance.error(test_case.shape)

    value =
      AshSmithy.Codec.from_node(
        {:structure, name, Enum.map(members, & &1.member)},
        test["params"] || %{}
      )

    conn = RestJson1.send_modeled_error(conn(:get, "/"), name, status, members, value)
    assert_response(conn, test["code"], test)
  end

  defp run(%{kind: :malformed, case: test} = test_case) do
    {operation, _} = Conformance.operation(test_case.shape)
    conn = build_request(test["request"])
    labels = route!(test_case, conn)

    conn = RestJson1.handle(conn, operation, labels, fn _input -> {:ok, %{}} end)
    expected = test["response"]

    assert conn.status == expected["code"],
           "expected status #{expected["code"]}, got #{conn.status}: #{conn.resp_body}"

    assert_headers(conn, expected["headers"] || %{})

    case expected["body"] do
      nil ->
        :ok

      %{"assertion" => %{"contents" => contents}, "mediaType" => "application/json"} ->
        assert Conformance.node_equal?(Jason.decode!(conn.resp_body), Jason.decode!(contents)),
               "body did not match.\n\nexpected: #{contents}\n\nactual:   #{conn.resp_body}"

      %{"assertion" => %{"contents" => contents}} ->
        assert conn.resp_body == contents

      %{"assertion" => %{"messageRegex" => regex}} ->
        message = Jason.decode!(conn.resp_body)["message"] || ""
        assert Regex.match?(Regex.compile!(regex), message), "#{inspect(message)} !~ #{regex}"
    end
  end

  defp assert_response(conn, code, test) do
    assert conn.status == code, "expected status #{code}, got #{conn.status}"
    assert_headers(conn, test["headers"] || %{})

    for header <- test["forbidHeaders"] || [] do
      assert get_resp_header(conn, String.downcase(header)) == [],
             "header #{header} should not be set"
    end

    for header <- test["requireHeaders"] || [] do
      assert get_resp_header(conn, String.downcase(header)) != [], "header #{header} is required"
    end

    case {test["body"], test["bodyMediaType"]} do
      {nil, _} ->
        :ok

      {"", _} ->
        assert conn.resp_body == "", "expected an empty body, got #{conn.resp_body}"

      {body, "application/json"} ->
        assert Conformance.node_equal?(Jason.decode!(conn.resp_body), Jason.decode!(body)),
               "body did not match.\n\nexpected: #{body}\n\nactual:   #{conn.resp_body}"

      {body, _} ->
        assert conn.resp_body == body
    end
  end

  defp assert_headers(conn, headers) do
    for {name, value} <- headers do
      assert get_resp_header(conn, String.downcase(name)) == [value],
             "expected header #{name}: #{inspect(value)}, got #{inspect(get_resp_header(conn, String.downcase(name)))}"
    end
  end

  defp build_request(request) do
    query =
      case request["queryParams"] do
        nil -> ""
        [] -> ""
        params -> "?" <> Enum.join(params, "&")
      end

    conn = conn(request["method"], request["uri"] <> query, request["body"] || "")

    Enum.reduce(request["headers"] || %{}, conn, fn {name, value}, conn ->
      put_req_header(conn, String.downcase(name), value)
    end)
    # Plug.Test sets a content type for bodies, which would hide missing content types
    |> then(fn conn ->
      if Enum.any?(Map.keys(request["headers"] || %{}), &(String.downcase(&1) == "content-type")) do
        conn
      else
        delete_req_header(conn, "content-type")
      end
    end)
  end

  # The request must be routed to the operation under test.
  defp route!(test_case, conn) do
    routes =
      Conformance.service_routes(test_case.service)

    case AshSmithy.Router.match(routes, conn) do
      {:ok, %{context: operation_id}, labels} ->
        assert operation_id == test_case.shape,
               "request was routed to #{operation_id} instead of #{test_case.shape}"

        labels

      :error ->
        flunk("no route matched #{conn.method} #{conn.request_path}?#{conn.query_string}")
    end
  end
end
