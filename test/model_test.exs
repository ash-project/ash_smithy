defmodule AshSmithy.ModelTest do
  use ExUnit.Case, async: true

  @ns "com.example.helpdesk#"

  setup_all do
    %{model: AshSmithy.Model.build(AshSmithy.Test.Helpdesk)}
  end

  defp shape(model, name), do: Map.fetch!(model["shapes"], @ns <> name)

  test "service", %{model: model} do
    service = shape(model, "Helpdesk")

    assert service["type"] == "service"
    assert service["version"] == "2026-10-01"
    assert service["traits"]["aws.protocols#restJson1"] == %{}
    assert service["traits"]["smithy.api#title"] == "Helpdesk Service"

    assert %{"target" => @ns <> "TicketResource"} in service["resources"]
    assert %{"target" => @ns <> "ValidationException"} in service["errors"]
  end

  test "resource", %{model: model} do
    resource = shape(model, "TicketResource")

    assert resource["identifiers"] == %{"ticketId" => %{"target" => "smithy.api#String"}}
    refute Map.has_key?(resource["properties"], "id")
    assert resource["properties"]["subject"] == %{"target" => "smithy.api#String"}
    assert resource["properties"]["status"] == %{"target" => @ns <> "TicketStatus"}
    assert resource["create"] == %{"target" => @ns <> "CreateTicket"}
    assert resource["read"] == %{"target" => @ns <> "GetTicket"}
    assert resource["delete"] == %{"target" => @ns <> "DeleteTicket"}
    assert resource["list"] == %{"target" => @ns <> "ListTickets"}
    assert resource["operations"] == [%{"target" => @ns <> "CloseTicket"}]
  end

  test "idempotency is never inferred", %{model: model} do
    refute Map.has_key?(shape(model, "UpdateTicket")["traits"], "smithy.api#idempotent")
    refute Map.has_key?(shape(model, "CloseTicket")["traits"], "smithy.api#idempotent")
    assert shape(model, "DeleteTicket")["traits"]["smithy.api#idempotent"] == %{}
  end

  test "read operations are readonly", %{model: model} do
    assert shape(model, "GetTicket")["traits"]["smithy.api#readonly"] == %{}
    assert shape(model, "ListTickets")["traits"]["smithy.api#readonly"] == %{}
    refute Map.has_key?(shape(model, "CreateTicket")["traits"], "smithy.api#readonly")
  end

  test "http bindings", %{model: model} do
    assert shape(model, "GetTicket")["traits"]["smithy.api#http"] == %{
             "method" => "GET",
             "uri" => "/tickets/{ticketId}",
             "code" => 200
           }

    input = shape(model, "GetTicketInput")

    assert input["members"]["ticketId"]["traits"] == %{
             "smithy.api#httpLabel" => %{},
             "smithy.api#required" => %{}
           }

    search = shape(model, "SearchTicketsInput")
    assert search["members"]["query"]["traits"]["smithy.api#httpQuery"] == "query"
  end

  test "input members", %{model: model} do
    members = shape(model, "CreateTicketInput")["members"]

    assert members["subject"]["traits"]["smithy.api#required"] == %{}
    assert members["subject"]["traits"]["smithy.api#length"] == %{"min" => 1, "max" => 200}
    refute Map.has_key?(members["body"], "traits")
    # Arguments aren't resource properties
    assert members["notify"]["traits"]["smithy.api#notProperty"] == %{}
  end

  test "static defaults are included in inputs", %{model: model} do
    create = shape(model, "CreateTicketInput")["members"]

    assert create["priority"]["traits"]["smithy.api#default"] == "medium"
    assert create["tags"]["traits"]["smithy.api#default"] == []
    assert create["notify"]["traits"]["smithy.api#default"] == false

    # defaults look like partial updates in update inputs
    update = shape(model, "UpdateTicketInput")["members"]
    refute Map.has_key?(update["priority"]["traits"] || %{}, "smithy.api#default")

    # outputs never get defaults, a nil value would be replaced by the client
    refute Map.has_key?(shape(model, "Ticket")["members"]["priority"], "traits")
  end

  test "function defaults are not included", %{model: model} do
    refute Map.has_key?(shape(model, "Widget")["members"]["id"]["traits"], "smithy.api#default")
  end

  test "calculations are not resource properties", %{model: model} do
    assert shape(model, "Ticket")["members"]["subjectLength"]["traits"] == %{
             "smithy.api#notProperty" => %{}
           }

    refute Map.has_key?(shape(model, "TicketResource")["properties"], "subjectLength")
  end

  test "action metadata is returned alongside records", %{model: model} do
    output = shape(model, "CreateTicketOutput")["members"]

    assert output["metadata"] == %{
             "target" => @ns <> "CreateTicketMetadata",
             "traits" => %{"smithy.api#notProperty" => %{}}
           }

    assert shape(model, "CreateTicketMetadata")["members"] == %{
             "notified" => %{
               "target" => "smithy.api#Boolean",
               "traits" => %{
                 "smithy.api#required" => %{},
                 "smithy.api#documentation" => "Whether anyone was notified."
               }
             }
           }

    assert shape(model, "DeleteTicketOutput")["members"]["metadata"]["target"] ==
             @ns <> "DeleteTicketMetadata"

    refute Map.has_key?(shape(model, "GetTicketOutput")["members"], "metadata")
  end

  test "list items carry action metadata", %{model: model} do
    assert shape(model, "SearchTicketsOutput")["members"]["tickets"]["target"] ==
             @ns <> "SearchTicketsItemList"

    assert shape(model, "SearchTicketsItem")["members"] == %{
             "ticket" => %{
               "target" => @ns <> "Ticket",
               "traits" => %{"smithy.api#required" => %{}}
             },
             "metadata" => %{"target" => @ns <> "SearchTicketsMetadata"}
           }

    # lists without metadata keep returning records directly
    assert shape(model, "ListTicketsOutput")["members"]["tickets"]["target"] ==
             @ns <> "TicketList"
  end

  test "list operations accept typed filters", %{model: model} do
    members = shape(model, "ListTicketsInput")["members"]

    assert members["status"] == %{
             "target" => @ns <> "TicketStatusValues",
             "traits" => %{
               "smithy.api#httpQuery" => "status",
               "smithy.api#documentation" =>
                 "Only return tickets whose `status` is one of the given values."
             }
           }

    assert shape(model, "TicketStatusValues")["member"] == %{"target" => @ns <> "TicketStatus"}
    assert members["estimateGte"]["target"] == "smithy.api#BigDecimal"
    assert members["insertedAtLt"]["traits"]["smithy.api#timestampFormat"] == "date-time"
    assert members["subjectContains"]["target"] == "smithy.api#String"
    assert members["bodyIsNil"]["target"] == "smithy.api#Boolean"

    # constraints describe field values, not filter values
    refute Map.has_key?(members["subjectContains"]["traits"], "smithy.api#length")
    # contains only applies to strings, not to identifiers or other string-like types
    refute Map.has_key?(members, "representativeIdContains")
    refute Map.has_key?(members, "idContains")
    # required fields can't be nil
    refute Map.has_key?(members, "subjectIsNil")
    # embedded/list types can't be filtered with query parameters
    refute Map.has_key?(members, "tags")
  end

  test "list operations accept typed sorts", %{model: model} do
    assert shape(model, "ListTicketsInput")["members"]["sort"]["target"] ==
             @ns <> "TicketSortFieldList"

    values = shape(model, "TicketSortField")["members"]

    assert values["INSERTED_AT_DESC"]["traits"]["smithy.api#enumValue"] == "-insertedAt"
    assert values["SUBJECT_ASC"]["traits"]["smithy.api#enumValue"] == "subject"
    # calculations can't be sorted on with keyset pagination
    refute Map.has_key?(values, "SUBJECT_LENGTH_ASC")
  end

  test "operations returning records accept includes", %{model: model} do
    assert shape(model, "GetTicketInput")["members"]["include"]["target"] ==
             @ns <> "TicketIncludeList"

    assert shape(model, "TicketInclude")["members"] == %{
             "REPRESENTATIVE" => %{
               "target" => "smithy.api#Unit",
               "traits" => %{"smithy.api#enumValue" => "representative"}
             }
           }

    refute Map.has_key?(shape(model, "DeleteTicketInput")["members"], "include")

    assert shape(model, "Ticket")["members"]["representative"] == %{
             "target" => @ns <> "Representative",
             "traits" => %{"smithy.api#notProperty" => %{}}
           }

    assert shape(model, "Representative")["members"]["tickets"]["target"] == @ns <> "TicketList"
  end

  test "belongs_to attributes reference the destination resource", %{model: model} do
    assert shape(model, "Ticket")["traits"]["smithy.api#references"] == [
             %{
               "resource" => @ns <> "RepresentativeResource",
               "ids" => %{"representativeId" => "representativeId"}
             }
           ]
  end

  test "maps without fields are maps of documents", %{model: model} do
    assert shape(model, "Widget")["members"]["settings"]["target"] == @ns <> "WidgetSettings"

    assert shape(model, "WidgetSettings") == %{
             "type" => "map",
             "key" => %{"target" => "smithy.api#String"},
             "value" => %{"target" => "smithy.api#Document"}
           }
  end

  test "pagination", %{model: model} do
    assert shape(model, "ListTickets")["traits"]["smithy.api#paginated"] == %{
             "inputToken" => "nextToken",
             "outputToken" => "nextToken",
             "pageSize" => "maxResults",
             "items" => "tickets"
           }

    assert shape(model, "ListTicketsInput")["members"]["maxResults"]["traits"]["smithy.api#range"] ==
             %{"min" => 1, "max" => 100}

    refute Map.has_key?(shape(model, "ListRepresentatives")["traits"], "smithy.api#paginated")
  end

  test "types", %{model: model} do
    members = shape(model, "Ticket")["members"]

    assert members["id"]["traits"]["smithy.api#resourceIdentifier"] == "ticketId"
    assert members["estimate"]["target"] == "smithy.api#BigDecimal"
    assert members["tags"]["target"] == @ns <> "TicketTagsList"
    assert members["priority"]["target"] == @ns <> "Priority"
    assert members["subjectLength"]["target"] == "smithy.api#Long"

    assert members["insertedAt"] == %{
             "target" => "smithy.api#Timestamp",
             "traits" => %{
               "smithy.api#timestampFormat" => "date-time",
               "smithy.api#required" => %{}
             }
           }

    refute Map.has_key?(members, "secret")

    assert shape(model, "Priority")["members"]["HIGH"] == %{
             "target" => "smithy.api#Unit",
             "traits" => %{"smithy.api#enumValue" => "high"}
           }

    assert %{"type" => "structure", "members" => %{"street" => _, "city" => _}} =
             shape(model, "Address")
  end

  test "errors", %{model: model} do
    assert shape(model, "NotFoundException")["traits"]["smithy.api#httpError"] == 404
    assert shape(model, "GetTicket")["errors"] == [%{"target" => @ns <> "NotFoundException"}]
    refute Map.has_key?(shape(model, "CreateTicket"), "errors")
  end

  test "to_json is stable" do
    assert AshSmithy.Model.to_json(AshSmithy.Test.Helpdesk) ==
             AshSmithy.Model.to_json(AshSmithy.Test.Helpdesk)
  end

  @smithy System.get_env("SMITHY_CLI") || System.find_executable("smithy")

  @tag :tmp_dir
  @tag skip: if(is_nil(@smithy), do: "smithy CLI not found, set SMITHY_CLI to run")
  test "the generated IDL passes smithy validation and matches the JSON AST", %{tmp_dir: tmp_dir} do
    Mix.Tasks.AshSmithy.Codegen.run([
      "--output",
      tmp_dir,
      "--format",
      "idl,json",
      "--domains",
      "AshSmithy.Test.Helpdesk"
    ])

    {output, status} =
      System.cmd(@smithy || "smithy", ["validate", "--severity", "WARNING"],
        cd: tmp_dir,
        stderr_to_stdout: true
      )

    assert status == 0, output
    refute output =~ "WARNING"

    {ast, 0} = System.cmd(@smithy || "smithy", ["ast"], cd: tmp_dir)

    from_idl =
      ast
      |> Jason.decode!()
      |> Map.fetch!("shapes")
      |> Map.filter(fn {id, _} -> String.starts_with?(id, @ns) end)

    json =
      tmp_dir
      |> Path.join("ast/ash_smithy_test_helpdesk.json")
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("shapes")

    # Smithy sorts reference lists, so compare without ordering
    assert normalize(from_idl) == normalize(json)
  end

  test "codegen --check raises when files are out of date" do
    tmp_dir =
      Path.join(System.tmp_dir!(), "ash_smithy_check_#{System.unique_integer([:positive])}")

    args = ["--output", tmp_dir, "--domains", "AshSmithy.Test.Helpdesk"]

    assert_raise Ash.Error.Framework.PendingCodegen, fn ->
      Mix.Tasks.AshSmithy.Codegen.run(args ++ ["--check"])
    end

    Mix.Tasks.AshSmithy.Codegen.run(args)
    Mix.Tasks.AshSmithy.Codegen.run(args ++ ["--check"])
    assert File.exists?(Path.join(tmp_dir, "model/ash_smithy_test_helpdesk.smithy"))
    File.rm_rf!(tmp_dir)
  end

  defp normalize(value) when is_map(value), do: Map.new(value, fn {k, v} -> {k, normalize(v)} end)
  defp normalize(value) when is_list(value), do: value |> Enum.map(&normalize/1) |> Enum.sort()
  defp normalize(value), do: value
end
