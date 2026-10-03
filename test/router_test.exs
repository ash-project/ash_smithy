defmodule AshSmithy.RouterTest do
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias AshSmithy.Test.Router

  defp request(method, path, body \\ nil, headers \\ []) do
    conn =
      if body do
        conn(method, path, Jason.encode!(body))
        |> put_req_header("content-type", "application/json")
      else
        conn(method, path)
      end

    conn =
      Enum.reduce(headers, conn, fn {key, value}, conn -> put_req_header(conn, key, value) end)

    conn = Router.call(conn, Router.init([]))
    body = if conn.resp_body in [nil, ""], do: nil, else: Jason.decode!(conn.resp_body)
    {conn, body}
  end

  defp open_ticket(attrs \\ %{}) do
    {conn, body} = request(:post, "/tickets", Map.merge(%{"subject" => "Help"}, attrs))
    assert conn.status == 200, inspect(body)
    body["ticket"]
  end

  test "create returns the created record" do
    {conn, body} =
      request(:post, "/tickets", %{
        "subject" => "Printer on fire",
        "priority" => "high",
        "tags" => ["hardware"],
        "estimate" => 1.25,
        "notify" => true
      })

    assert conn.status == 200
    assert ["application/json" <> _] = get_resp_header(conn, "content-type")

    assert %{
             "ticket" => %{
               "id" => id,
               "subject" => "Printer on fire",
               "status" => "open",
               "priority" => "high",
               "tags" => ["hardware"],
               "estimate" => 1.25,
               "insertedAt" => inserted_at,
               "subjectLength" => 15
             }
           } = body

    assert is_binary(id)
    assert {:ok, _, _} = DateTime.from_iso8601(inserted_at)
  end

  test "create returns action metadata" do
    {_conn, body} = request(:post, "/tickets", %{"subject" => "x", "notify" => true})
    assert %{"ticket" => _, "metadata" => %{"notified" => true}} = body

    {_conn, body} = request(:post, "/tickets", %{"subject" => "x"})
    assert %{"metadata" => %{"notified" => false}} = body
  end

  test "delete returns action metadata" do
    %{"id" => id} = open_ticket(%{"subject" => "Bye"})
    {conn, body} = request(:delete, "/tickets/#{id}")

    assert conn.status == 200
    assert body == %{"metadata" => %{"destroyedSubject" => "Bye"}}
  end

  test "list items carry action metadata" do
    open_ticket(%{"subject" => "The printer is broken"})

    {conn, body} = request(:get, "/tickets/search?query=printer")
    assert conn.status == 200

    assert %{
             "tickets" => [
               %{
                 "ticket" => %{"subject" => "The printer is broken"},
                 "metadata" => %{"matchPosition" => 4}
               }
             ]
           } = body
  end

  test "nil values are omitted" do
    ticket = open_ticket()
    refute Map.has_key?(ticket, "body")
    refute Map.has_key?(ticket, "secret")
  end

  test "validation errors are returned as ValidationException" do
    {conn, body} = request(:post, "/tickets", %{"body" => "no subject"})

    assert conn.status == 400
    assert get_resp_header(conn, "x-amzn-errortype") == ["ValidationException"]
    assert %{"message" => _, "fieldList" => [%{"path" => "/subject", "message" => _}]} = body
  end

  test "invalid enum values are rejected before reaching Ash" do
    {conn, body} = request(:post, "/tickets", %{"subject" => "x", "priority" => "urgent"})

    assert conn.status == 400
    assert %{"fieldList" => [%{"path" => "/priority"}]} = body
  end

  test "invalid JSON is rejected" do
    conn =
      conn(:post, "/tickets", "{nope")
      |> put_req_header("content-type", "application/json")
      |> Router.call([])

    assert conn.status == 400
    assert get_resp_header(conn, "x-amzn-errortype") == ["SerializationException"]
  end

  test "get by identifier" do
    %{"id" => id} = open_ticket()
    {conn, body} = request(:get, "/tickets/#{id}")

    assert conn.status == 200
    assert %{"ticket" => %{"id" => ^id}} = body
  end

  test "get with an unknown identifier returns NotFoundException" do
    {conn, body} = request(:get, "/tickets/#{Ash.UUID.generate()}")

    assert conn.status == 404
    assert get_resp_header(conn, "x-amzn-errortype") == ["NotFoundException"]
    assert %{"message" => _} = body
  end

  test "get with an uncastable identifier returns NotFoundException" do
    {conn, _body} = request(:get, "/tickets/not-a-uuid")
    assert conn.status == 404
  end

  test "update" do
    %{"id" => id} = open_ticket()
    {conn, body} = request(:patch, "/tickets/#{id}", %{"subject" => "Updated"})

    assert conn.status == 200
    assert %{"ticket" => %{"id" => ^id, "subject" => "Updated"}} = body
  end

  test "instance operation" do
    %{"id" => id} = open_ticket()
    {conn, body} = request(:post, "/tickets/#{id}/close")

    assert conn.status == 200
    assert %{"ticket" => %{"status" => "closed"}} = body
  end

  test "delete returns an empty object" do
    %{"id" => id} = open_ticket()
    {conn, body} = request(:delete, "/tickets/#{id}")

    assert conn.status == 200
    assert Map.keys(body) == ["metadata"]

    assert {404, _} =
             then(request(:get, "/tickets/#{id}"), fn {conn, body} -> {conn.status, body} end)
  end

  test "list paginates with nextToken" do
    for i <- 1..5, do: open_ticket(%{"subject" => "Ticket #{i}"})

    {conn, body} = request(:get, "/tickets?maxResults=2")
    assert conn.status == 200
    assert %{"tickets" => [_, _] = first, "nextToken" => token} = body

    {_conn, body} = request(:get, "/tickets?maxResults=2&nextToken=#{URI.encode_www_form(token)}")
    assert %{"tickets" => [_, _] = second, "nextToken" => token} = body

    {_conn, body} = request(:get, "/tickets?maxResults=2&nextToken=#{URI.encode_www_form(token)}")
    assert %{"tickets" => [_] = third} = body
    refute Map.has_key?(body, "nextToken")

    ids = Enum.map(first ++ second ++ third, & &1["id"])
    assert Enum.uniq(ids) == ids
    assert length(ids) == 5
  end

  describe "filtering and sorting" do
    setup do
      a = open_ticket(%{"subject" => "Alpha", "estimate" => 1, "priority" => "low"})
      b = open_ticket(%{"subject" => "Beta", "estimate" => 5, "body" => "has a body"})
      c = open_ticket(%{"subject" => "Gamma", "estimate" => 10, "priority" => "high"})
      %{a: a["id"], b: b["id"], c: c["id"]}
    end

    defp ids(query) do
      {conn, body} = request(:get, "/tickets?" <> query)
      assert conn.status == 200, inspect(body)
      Enum.map(body["tickets"], & &1["id"])
    end

    test "equality and in filters", %{a: a, c: c} do
      assert ids("priority=low") == [a]
      assert ids("priority=low&priority=high") == [a, c]
    end

    test "range filters", %{b: b, c: c} do
      assert ids("estimateGte=5") == [b, c]
      assert ids("estimateGt=5&estimateLt=11") == [c]
    end

    test "string function filters", %{a: a, b: b} do
      assert ids("subjectStartsWith=Al") == [a]
      assert ids("subjectEndsWith=ta") == [b]
    end

    test "contains and is nil filters", %{a: a, b: b, c: c} do
      assert ids("subjectContains=mm") == [c]
      assert ids("bodyIsNil=false") == [b]
      assert ids("bodyIsNil=true") == [a, c]
    end

    test "sorting", %{a: a, b: b, c: c} do
      assert ids("sort=-estimate") == [c, b, a]
      assert ids("sort=priority&sort=-subject") == [c, a, b]
    end

    test "sorting with pagination", %{a: a, b: b, c: c} do
      {_, body} = request(:get, "/tickets?sort=-subject&maxResults=2")
      assert Enum.map(body["tickets"], & &1["id"]) == [c, b]

      {_, body} =
        request(
          :get,
          "/tickets?sort=-subject&maxResults=2&nextToken=#{URI.encode_www_form(body["nextToken"])}"
        )

      assert Enum.map(body["tickets"], & &1["id"]) == [a]
    end

    test "invalid filter and sort values are rejected" do
      {conn, _body} = request(:get, "/tickets?estimateGt=abc")
      assert conn.status == 400
      assert get_resp_header(conn, "x-amzn-errortype") == ["SerializationException"]

      {conn, body} = request(:get, "/tickets?sort=nope")
      assert conn.status == 400
      assert get_resp_header(conn, "x-amzn-errortype") == ["ValidationException"]
      assert %{"fieldList" => [%{"path" => "/sort/0"}]} = body
    end
  end

  describe "includes" do
    test "to-one relationships" do
      {_, %{"representative" => %{"id" => rep_id}}} =
        request(:post, "/representatives", %{"name" => "Ada"})

      %{"id" => id} = open_ticket(%{"representativeId" => rep_id})

      {_, body} = request(:get, "/tickets/#{id}")
      refute Map.has_key?(body["ticket"], "representative")

      {_, body} = request(:get, "/tickets/#{id}?include=representative")
      assert %{"representative" => %{"id" => ^rep_id, "name" => "Ada"}} = body["ticket"]
    end

    test "to-many relationships, with the calculations of related records" do
      {_, %{"representative" => %{"id" => rep_id}}} =
        request(:post, "/representatives", %{"name" => "Ada"})

      open_ticket(%{"subject" => "One", "representativeId" => rep_id})
      open_ticket(%{"subject" => "Two", "representativeId" => rep_id})

      {_, body} = request(:get, "/representatives/#{rep_id}?include=tickets")

      assert [%{"subject" => "One", "subjectLength" => 3}, %{"subject" => "Two"}] =
               Enum.sort_by(body["representative"]["tickets"], & &1["subject"])

      {_, body} = request(:get, "/representatives?include=tickets")
      assert [%{"tickets" => [_, _]}] = body["representatives"]
    end

    test "includes on create" do
      {_, %{"representative" => %{"id" => rep_id}}} =
        request(:post, "/representatives", %{"name" => "Ada"})

      {conn, body} =
        request(:post, "/tickets?include=representative", %{
          "subject" => "x",
          "representativeId" => rep_id
        })

      assert conn.status == 200
      assert %{"ticket" => %{"representative" => %{"name" => "Ada"}}} = body
    end

    test "unknown includes are rejected" do
      {conn, body} = request(:get, "/tickets?include=nope")
      assert conn.status == 400
      assert %{"fieldList" => [%{"path" => "/include/0"}]} = body
    end
  end

  test "maxResults must be an integer" do
    {conn, body} = request(:get, "/tickets?maxResults=abc")
    assert conn.status == 400
    assert get_resp_header(conn, "x-amzn-errortype") == ["SerializationException"]
    assert %{"message" => _} = body
  end

  test "collection operation with query input" do
    open_ticket(%{"subject" => "Network down"})
    open_ticket(%{"subject" => "Printer jam"})

    {conn, body} = request(:get, "/tickets/search?query=Printer")
    assert conn.status == 200
    assert %{"tickets" => [%{"ticket" => %{"subject" => "Printer jam"}}]} = body
  end

  test "literal segments are preferred over labels" do
    {conn, _body} = request(:get, "/tickets/search?query=x")
    assert conn.status == 200
  end

  test "generic action" do
    open_ticket()
    open_ticket()
    {conn, body} = request(:get, "/tickets/count-open")
    assert conn.status == 200
    assert %{"result" => 2} = body
  end

  test "embedded resources are encoded and decoded" do
    {conn, body} =
      request(:post, "/representatives", %{
        "name" => "Ada",
        "address" => %{"street" => "1 Main St", "city" => "Springfield"}
      })

    assert conn.status == 200
    assert %{"representative" => %{"address" => %{"street" => "1 Main St"}}} = body
  end

  test "unknown operations" do
    {conn, _body} = request(:get, "/nope")
    assert conn.status == 404
    assert get_resp_header(conn, "x-amzn-errortype") == ["UnknownOperationException"]
  end

  test "serves the model" do
    {conn, body} = request(:get, "/model.json")
    assert conn.status == 200
    assert %{"smithy" => "2.0", "shapes" => %{}} = body
  end

  describe "widgets" do
    test "unions, maps with fields and lists of embedded resources round trip" do
      {conn, body} =
        request(:post, "/widgets", %{
          "name" => "Gizmo",
          "content" => %{"address" => %{"street" => "1 Main St"}},
          "dimensions" => %{"width" => 1.5, "height" => 2, "unit" => "cm"},
          "addresses" => [%{"street" => "A"}, %{"street" => "B", "city" => "C"}],
          "settings" => %{"anything" => [1, "two"]}
        })

      assert conn.status == 200, inspect(body)

      assert %{
               "widget" => %{
                 "id" => id,
                 "content" => %{"address" => %{"street" => "1 Main St"}},
                 "dimensions" => %{"width" => 1.5, "unit" => "cm"},
                 "addresses" => [%{"street" => "A"}, %{"street" => "B", "city" => "C"}],
                 "settings" => %{"anything" => [1, "two"]}
               }
             } = body

      # integer identifiers are modeled as strings
      assert is_binary(id)

      {conn, body} = request(:patch, "/widgets/#{id}", %{"content" => %{"number" => 10}})
      assert conn.status == 200, inspect(body)
      assert %{"widget" => %{"content" => %{"number" => 10}}} = body

      {conn, body} = request(:post, "/widgets/#{id}/rename", %{"name" => "Renamed"})
      assert conn.status == 200, inspect(body)
      assert %{"widget" => %{"name" => "Renamed"}} = body

      {conn, body} = request(:get, "/widgets/#{id}/lookup?includeArchived=true")

      assert conn.status == 200, inspect(body)
      assert %{"widget" => %{"id" => ^id}} = body
    end

    test "maps without fields must be objects" do
      {conn, body} = request(:post, "/widgets", %{"name" => "x", "settings" => [1, 2]})
      assert conn.status == 400
      assert get_resp_header(conn, "x-amzn-errortype") == ["SerializationException"]
      assert %{"message" => _} = body
    end

    test "read and list return metadata" do
      {_conn, %{"widget" => %{"id" => id}}} = request(:post, "/widgets", %{"name" => "four"})

      assert {_, %{"widget" => %{"id" => ^id}, "metadata" => %{"nameLength" => 4}}} =
               request(:get, "/widgets/#{id}")

      {_conn, body} = request(:get, "/widgets")

      assert %{"widget" => %{"id" => ^id}, "metadata" => %{"nameLength" => 4}} =
               Enum.find(body["widgets"], &(&1["widget"]["id"] == id))
    end

    test "unions require exactly one member" do
      {conn, body} =
        request(:post, "/widgets", %{"name" => "x", "content" => %{"text" => "a", "number" => 1}})

      assert conn.status == 400
      assert get_resp_header(conn, "x-amzn-errortype") == ["SerializationException"]
      assert %{"message" => _} = body
    end

    test "generic actions returning records" do
      {conn, body} = request(:post, "/widgets/featured")
      assert conn.status == 200, inspect(body)
      assert %{"result" => %{"id" => "1", "name" => "featured"}} = body
    end
  end
end
