defmodule AshSmithy.Test.Conformance do
  @moduledoc false
  # Runs the Smithy protocol compliance tests for `aws.protocols#restJson1` against
  # `AshSmithy.Protocols.RestJson1`.
  #
  # The test models (from `software.amazon.smithy:smithy-aws-protocol-tests`) are converted
  # into `AshSmithy.Plan.Operation`s, the same structures the server builds from Ash
  # resources, so the cases exercise the real routing, decoding, validation and encoding code.

  alias AshSmithy.Plan.{Binding, Operation}
  alias AshSmithy.Type.Member

  @services [
    "aws.protocoltests.restjson#RestJson",
    "aws.protocoltests.restjson.validation#RestJsonValidation"
  ]

  @protocol "aws.protocols#restJson1"

  @ast_path Path.expand("../../_build/smithy-protocol-tests.json", __DIR__)

  def ast_path, do: @ast_path

  @doc "Generates the protocol tests AST with the Smithy CLI, if it isn't cached."
  def ensure_ast! do
    smithy = System.get_env("SMITHY_CLI") || System.find_executable("smithy")

    cond do
      File.exists?(@ast_path) ->
        :ok

      is_nil(smithy) ->
        :unavailable

      true ->
        dir = Path.join(System.tmp_dir!(), "ash_smithy_protocol_tests")
        File.mkdir_p!(dir)

        File.write!(
          Path.join(dir, "smithy-build.json"),
          Jason.encode!(%{
            "version" => "1.0",
            "maven" => %{
              "dependencies" => ["software.amazon.smithy:smithy-aws-protocol-tests:1.74.0"]
            }
          })
        )

        {ast, 0} = System.cmd(smithy, ["ast"], cd: dir, stderr_to_stdout: false)
        File.mkdir_p!(Path.dirname(@ast_path))
        File.write!(@ast_path, ast)
        :ok
    end
  end

  @doc "Loads the test model, returning the list of test cases."
  def cases do
    shapes = shapes()

    Enum.flat_map(@services, fn service ->
      operations = service_operations(shapes, service)

      operation_cases =
        Enum.flat_map(operations, fn operation_id ->
          traits = shapes[operation_id]["traits"] || %{}

          Enum.concat([
            server_cases(traits, "smithy.test#httpRequestTests", :request, service, operation_id),
            server_cases(
              traits,
              "smithy.test#httpResponseTests",
              :response,
              service,
              operation_id
            ),
            traits
            |> server_cases(
              "smithy.test#httpMalformedRequestTests",
              :malformed,
              service,
              operation_id
            )
            |> Enum.flat_map(&expand_parameters/1)
          ])
        end)

      error_cases =
        operations
        |> Enum.flat_map(&(shapes[&1]["errors"] || []))
        |> Enum.map(& &1["target"])
        |> Enum.uniq()
        |> Enum.flat_map(fn error_id ->
          server_cases(
            shapes[error_id]["traits"] || %{},
            "smithy.test#httpResponseTests",
            :error,
            service,
            error_id
          )
        end)

      operation_cases ++ error_cases
    end)
  end

  defp server_cases(traits, trait, kind, service, shape_id) do
    traits
    |> Map.get(trait, [])
    |> Enum.filter(&(&1["appliesTo"] in [nil, "server"] and &1["protocol"] == @protocol))
    |> Enum.map(&%{kind: kind, service: service, shape: shape_id, id: &1["id"], case: &1})
  end

  # One case per index of the test parameters, with parameters substituted into every string.
  defp expand_parameters(%{case: %{"testParameters" => params} = test} = test_case)
       when map_size(params) > 0 do
    count = params |> Map.values() |> hd() |> length()

    for index <- 0..(count - 1) do
      values = Map.new(params, fn {key, values} -> {key, Enum.at(values, index)} end)

      %{
        test_case
        | id: "#{test_case.id}_#{index}",
          case: substitute(Map.delete(test, "testParameters"), values)
      }
    end
  end

  # `$$` is an escaped `$`, even when there are no parameters
  defp expand_parameters(test_case), do: [%{test_case | case: substitute(test_case.case, %{})}]

  defp substitute(value, params) when is_binary(value) do
    ~r/\$\$|\$(\w+):([LS])/
    |> Regex.replace(value, fn
      "$$", _, _ -> "$"
      token, name, _ when not is_map_key(params, name) -> token
      _, name, "L" -> params[name]
      _, name, "S" -> Jason.encode!(params[name])
    end)
  end

  defp substitute(value, params) when is_list(value), do: Enum.map(value, &substitute(&1, params))

  defp substitute(value, params) when is_map(value),
    do: Map.new(value, fn {key, value} -> {key, substitute(value, params)} end)

  defp substitute(value, _params), do: value

  defp service_operations(shapes, service) do
    service = shapes[service]

    resource_operations =
      service
      |> Map.get("resources", [])
      |> Enum.flat_map(fn %{"target" => resource} ->
        resource = shapes[resource]

        ~w(create put read update delete list)
        |> Enum.flat_map(&List.wrap(resource[&1]))
        |> Enum.concat(resource["operations"] || [])
        |> Enum.concat(resource["collectionOperations"] || [])
      end)

    (Map.get(service, "operations", []) ++ resource_operations)
    |> Enum.map(& &1["target"])
    |> Enum.uniq()
  end

  @doc "Routes for every operation of a service, as `AshSmithy.Router` builds them."
  def service_routes(service) do
    case :persistent_term.get({__MODULE__, :routes, service}, nil) do
      nil ->
        routes =
          shapes()
          |> service_operations(service)
          |> Enum.map(fn operation_id ->
            {operation, _} = operation(operation_id)
            AshSmithy.Router.route(operation, operation_id)
          end)
          |> AshSmithy.Router.sort_routes()

        :persistent_term.put({__MODULE__, :routes, service}, routes)
        routes

      routes ->
        routes
    end
  end

  ## Conversion

  defp shapes do
    case :persistent_term.get({__MODULE__, :shapes}, nil) do
      nil ->
        shapes = @ast_path |> File.read!() |> Jason.decode!() |> Map.fetch!("shapes")
        :persistent_term.put({__MODULE__, :shapes}, shapes)
        shapes

      shapes ->
        shapes
    end
  end

  @doc "Converts an operation in the test model to an `AshSmithy.Plan.Operation`."
  def operation(operation_id) do
    shape = shapes()[operation_id]
    traits = shape["traits"] || %{}
    http = traits["smithy.api#http"]

    {input, input_unsupported} = bindings(shape["input"], :input)
    {output, output_unsupported} = bindings(shape["output"], :output)

    unsupported =
      Enum.uniq(input_unsupported ++ output_unsupported ++ operation_unsupported(traits))

    operation = %Operation{
      name: name(operation_id),
      method: http["method"],
      uri: http["uri"],
      code: http["code"] || 200,
      input: input,
      output_members: output,
      errors: Enum.map(shape["errors"] || [], &name(&1["target"]))
    }

    {operation, unsupported}
  end

  @doc "The status code, name and member bindings of an error structure."
  def error(error_id) do
    shape = shapes()[error_id]
    traits = shape["traits"] || %{}
    {members, unsupported} = bindings(%{"target" => error_id}, :output)

    status =
      traits["smithy.api#httpError"] ||
        if traits["smithy.api#error"] == "server", do: 500, else: 400

    {name(error_id), status, members, unsupported}
  end

  defp operation_unsupported(traits) do
    for trait <- ["smithy.api#endpoint", "smithy.api#requestCompression"],
        Map.has_key?(traits, trait),
        do: trait
  end

  # Returns `nil` bindings for `smithy.api#Unit`.
  defp bindings(nil, _direction), do: {nil, []}
  defp bindings(%{"target" => "smithy.api#Unit"}, _direction), do: {nil, []}

  defp bindings(%{"target" => target}, direction) do
    shape = shapes()[target]

    Enum.reduce(members(shape), {[], []}, fn {name, member_shape}, {bindings, unsupported} ->
      traits = member_shape["traits"] || %{}
      member = member(name, member_shape)

      {location, location_name} =
        cond do
          Map.has_key?(traits, "smithy.api#httpLabel") ->
            {:label, name}

          Map.has_key?(traits, "smithy.api#httpQuery") ->
            {:query, traits["smithy.api#httpQuery"]}

          Map.has_key?(traits, "smithy.api#httpHeader") ->
            {:header, traits["smithy.api#httpHeader"]}

          Map.has_key?(traits, "smithy.api#httpResponseCode") ->
            {:response_code, name}

          Map.has_key?(traits, "smithy.api#httpPayload") ->
            {:unsupported, "smithy.api#httpPayload"}

          Map.has_key?(traits, "smithy.api#httpPrefixHeaders") ->
            {:prefix_headers, traits["smithy.api#httpPrefixHeaders"]}

          Map.has_key?(traits, "smithy.api#httpQueryParams") ->
            {:query_params, name}

          true ->
            {:body, name}
        end

      case location do
        :unsupported ->
          {bindings, [location_name | unsupported]}

        location ->
          {bindings ++
             [
               %Binding{
                 member: member,
                 source: direction,
                 location: location,
                 location_name: location_name
               }
             ], unsupported}
      end
    end)
  end

  defp member(name, member_shape) do
    target = member_shape["target"]
    traits = member_shape["traits"] || %{}

    %Member{
      name: name,
      member: name,
      descriptor: descriptor(target),
      required?: Map.has_key?(traits, "smithy.api#required"),
      # Constraints on non-simple targets (e.g. a list's length) apply through the member
      traits: Map.merge(container_traits(target), traits)
    }
  end

  defp container_traits(target) do
    case shapes()[target] do
      %{"type" => type} = shape when type in ["list", "map", "structure", "union"] ->
        Map.take(shape["traits"] || %{}, ["smithy.api#length", "smithy.api#uniqueItems"])

      _ ->
        %{}
    end
  end

  @prelude %{
    "String" => "String",
    "Blob" => "Blob",
    "Boolean" => "Boolean",
    "PrimitiveBoolean" => "Boolean",
    "Byte" => "Byte",
    "PrimitiveByte" => "Byte",
    "Short" => "Short",
    "PrimitiveShort" => "Short",
    "Integer" => "Integer",
    "PrimitiveInteger" => "Integer",
    "Long" => "Long",
    "PrimitiveLong" => "Long",
    "Float" => "Float",
    "PrimitiveFloat" => "Float",
    "Double" => "Double",
    "PrimitiveDouble" => "Double",
    "BigInteger" => "BigInteger",
    "BigDecimal" => "BigDecimal",
    "Timestamp" => "Timestamp",
    "Document" => "Document",
    "Unit" => "Unit"
  }

  @simple %{
    "string" => "String",
    "blob" => "Blob",
    "boolean" => "Boolean",
    "byte" => "Byte",
    "short" => "Short",
    "integer" => "Integer",
    "long" => "Long",
    "float" => "Float",
    "double" => "Double",
    "bigInteger" => "BigInteger",
    "bigDecimal" => "BigDecimal",
    "timestamp" => "Timestamp",
    "document" => "Document"
  }

  @doc false
  def descriptor("smithy.api#" <> prelude), do: {:simple, Map.fetch!(@prelude, prelude), %{}}

  def descriptor(target) do
    shape = shapes()[target]
    traits = shape["traits"] || %{}

    case shape["type"] do
      "string" when is_map_key(traits, "smithy.api#enum") ->
        {:enum, name(target),
         Enum.map(traits["smithy.api#enum"], fn definition ->
           value = definition["value"]

           if "internal" in (definition["tags"] || []),
             do: {value, value, :internal},
             else: {value, value}
         end)}

      type when is_map_key(@simple, type) ->
        {:simple, Map.fetch!(@simple, type), traits}

      "enum" ->
        {:enum, name(target),
         Enum.map(shape["members"], fn {name, member} ->
           member_traits = member["traits"] || %{}
           value = member_traits["smithy.api#enumValue"] || name

           if Map.has_key?(member_traits, "smithy.api#internal"),
             do: {name, value, :internal},
             else: {name, value}
         end)}

      "intEnum" ->
        {:int_enum, name(target),
         Enum.map(shape["members"], fn {name, member} ->
           {name, member["traits"]["smithy.api#enumValue"]}
         end)}

      "list" ->
        {:list, name(target), member_descriptor(shape["member"]),
         Map.has_key?(traits, "smithy.api#sparse")}

      "map" ->
        {:map, name(target), member_descriptor(shape["key"]), member_descriptor(shape["value"]),
         Map.has_key?(traits, "smithy.api#sparse")}

      type when type in ["structure", "union"] ->
        # Structures may be recursive, so they are expanded lazily
        {:lazy, __MODULE__, :aggregate, [target]}
    end
  end

  @doc false
  def aggregate(target) do
    shape = shapes()[target]

    {String.to_atom(shape["type"]), name(target),
     Enum.map(members(shape), fn {name, member_shape} -> member(name, member_shape) end)}
  end

  # The traits of a list member or map key/value apply to the values themselves.
  defp member_descriptor(%{"target" => target} = member) do
    case descriptor(target) do
      {:simple, type, traits} ->
        {:simple, type, Map.merge(traits, member["traits"] || %{})}

      descriptor ->
        case Map.merge(container_traits(target), member["traits"] || %{}) do
          empty when empty == %{} -> descriptor
          traits -> {:constrained, descriptor, traits}
        end
    end
  end

  # Members of a shape, including those of its mixins. `smithy ast` doesn't flatten mixins.
  defp members(shape) do
    shape
    |> Map.get("mixins", [])
    |> Enum.map(&members(shapes()[&1["target"]]))
    |> Enum.reduce(%{}, &Map.merge(&2, &1))
    |> Map.merge(shape["members"] || %{})
  end

  defp name(shape_id), do: shape_id |> String.split("#") |> List.last()

  ## Node values

  @doc "Converts a decoded value to a Smithy node value, for comparison with test params."
  def to_node(_descriptor, nil), do: nil
  def to_node({:lazy, m, f, a}, value), do: to_node(apply(m, f, a), value)

  def to_node({:simple, "Timestamp", _}, %DateTime{} = value) do
    case DateTime.to_unix(value, :microsecond) do
      micros when rem(micros, 1_000_000) == 0 -> div(micros, 1_000_000)
      micros -> micros / 1_000_000
    end
  end

  def to_node({:simple, "BigDecimal", _}, %Decimal{} = value), do: Decimal.to_float(value)

  def to_node({:simple, type, _}, value) when type in ["Float", "Double"] do
    case value do
      :nan -> "NaN"
      :infinity -> "Infinity"
      :negative_infinity -> "-Infinity"
      value -> value
    end
  end

  def to_node({:list, _, member, _}, values), do: Enum.map(values, &to_node(member, &1))

  def to_node({:map, _, _, member, _}, values),
    do: Map.new(values, fn {key, value} -> {key, to_node(member, value)} end)

  def to_node({:structure, _, members}, value) do
    Enum.reduce(members, %{}, fn member, acc ->
      case Map.fetch(value, member.name) do
        {:ok, field_value} -> Map.put(acc, member.member, to_node(member.descriptor, field_value))
        :error -> acc
      end
    end)
  end

  def to_node({:union, _, members}, %Ash.Union{type: type, value: value}) do
    member = Enum.find(members, &(&1.name == type))
    %{member.member => to_node(member.descriptor, value)}
  end

  def to_node(_descriptor, value), do: value

  @doc "Compares node values, treating integers and floats with the same value as equal."
  def node_equal?(left, right) when is_number(left) and is_number(right), do: left == right

  def node_equal?(left, right) when is_map(left) and is_map(right) do
    Map.keys(left) |> Enum.sort() == Map.keys(right) |> Enum.sort() and
      Enum.all?(left, fn {key, value} -> node_equal?(value, right[key]) end)
  end

  def node_equal?(left, right) when is_list(left) and is_list(right) do
    length(left) == length(right) and
      Enum.all?(Enum.zip(left, right), fn {left, right} -> node_equal?(left, right) end)
  end

  def node_equal?(left, right), do: left == right

  @doc """
  Normalizes expected params: null structure members are equivalent to absent ones.
  """
  def normalize(_descriptor, nil), do: nil
  def normalize({:lazy, m, f, a}, value), do: normalize(apply(m, f, a), value)
  def normalize({:list, _, member, _}, values), do: Enum.map(values, &normalize(member, &1))

  def normalize({:map, _, _, member, _}, values),
    do: Map.new(values, fn {key, value} -> {key, normalize(member, value)} end)

  def normalize({:structure, _, members}, value) do
    Enum.reduce(members, %{}, fn member, acc ->
      case Map.fetch(value, member.member) do
        {:ok, nil} ->
          acc

        {:ok, field_value} ->
          Map.put(acc, member.member, normalize(member.descriptor, field_value))

        :error ->
          acc
      end
    end)
  end

  def normalize({:union, _, members}, value) do
    Map.new(value, fn {key, value} ->
      member = Enum.find(members, &(&1.member == key))
      {key, if(member, do: normalize(member.descriptor, value), else: value)}
    end)
  end

  def normalize(_descriptor, value), do: value
end
