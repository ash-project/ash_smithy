defmodule AshSmithy.Codec do
  @moduledoc """
  Encodes and decodes values according to `AshSmithy.Type` descriptors, following the
  serialization rules of Smithy's JSON based HTTP protocols.

  Decoding is strict: values of the wrong type are rejected with a serialization error.
  Constraint traits are checked separately by `AshSmithy.Validation`.

  Decoded values are:

    * timestamps - `DateTime`
    * floats and doubles - floats, or `:nan`, `:infinity` and `:negative_infinity`
    * big decimals - `Decimal`
    * blobs - binaries
    * enums - strings, int enums - integers
    * structures - maps keyed by member name
    * unions - `Ash.Union` structs
    * maps - maps with string keys
  """

  alias AshSmithy.Type.Member

  @int_ranges %{
    "Byte" => {-128, 127},
    "Short" => {-32_768, 32_767},
    "Integer" => {-2_147_483_648, 2_147_483_647},
    "Long" => {-9_223_372_036_854_775_808, 9_223_372_036_854_775_807}
  }

  @floats ["Float", "Double"]

  @type location :: :body | :header | :query | :label

  ## Timestamp formats

  @doc "The timestamp format for a value, given the member and descriptor traits and its location."
  def timestamp_format(traits, location) do
    traits["smithy.api#timestampFormat"] ||
      case location do
        :body -> "epoch-seconds"
        :header -> "http-date"
        _ -> "date-time"
      end
  end

  @doc "The traits that apply to a member: its own traits over those of its target."
  def traits(%Member{} = member),
    do: Map.merge(descriptor_traits(member.descriptor), member.traits || %{})

  def descriptor_traits({:simple, _, traits}), do: traits

  def descriptor_traits({:constrained, descriptor, traits}),
    do: Map.merge(descriptor_traits(descriptor), traits)

  def descriptor_traits(_), do: %{}

  @doc false
  # Strips the `{:constrained, descriptor, traits}` wrapper, used for constraints on list members
  # and map values that aren't simple shapes.
  def unwrap({:constrained, descriptor, _traits}), do: unwrap(descriptor)
  def unwrap(descriptor), do: descriptor

  ## Encoding

  @doc """
  Encodes an Elixir value into a JSON-encodable term for a body.
  """
  @spec encode(AshSmithy.Type.descriptor(), term, map) :: term
  def encode(descriptor, value, traits \\ %{})
  def encode(_descriptor, nil, _traits), do: nil

  def encode({:resource, resource}, value, traits) do
    encode(AshSmithy.Type.resource_structure(resource), value, traits)
  end

  def encode({:lazy, m, f, a}, value, traits), do: encode(apply(m, f, a), value, traits)
  def encode({:constrained, descriptor, _}, value, traits), do: encode(descriptor, value, traits)
  def encode({:simple, "Unit", _}, _value, _traits), do: %{}

  def encode({:simple, "Timestamp", descriptor_traits}, value, traits) do
    format = timestamp_format(Map.merge(descriptor_traits, traits), :body)
    encode_timestamp(to_datetime(value), format)
  end

  def encode({:simple, "Blob", _}, value, _traits) when is_binary(value), do: Base.encode64(value)

  def encode({:simple, type, _}, %Decimal{} = value, _traits)
      when type in ["BigDecimal", "BigInteger"] do
    value |> Decimal.to_string(:normal) |> Jason.Fragment.new()
  end

  def encode({:simple, type, _}, value, _traits) when type in @floats do
    case value do
      :nan -> "NaN"
      :infinity -> "Infinity"
      :negative_infinity -> "-Infinity"
      %Decimal{} -> Decimal.to_float(value)
      value -> value
    end
  end

  def encode({:simple, "String", _}, value, _traits) when is_atom(value), do: to_string(value)

  def encode({:simple, "String", _}, value, _traits) do
    if String.Chars.impl_for(value), do: to_string(value), else: value
  end

  def encode({:simple, "Document", _}, value, _traits), do: encode_document(value)
  def encode({:simple, _, _}, value, _traits), do: value

  def encode({:enum, _, _}, value, _traits), do: to_string(value)
  def encode({:int_enum, _, _}, value, _traits), do: value

  def encode({:list, _, member, sparse?}, value, _traits) do
    value
    |> List.wrap()
    |> Enum.map(&encode(member, &1))
    |> then(fn values -> if sparse?, do: values, else: Enum.reject(values, &is_nil/1) end)
  end

  def encode({:map, _, _key, member, sparse?}, value, _traits) do
    value
    |> Enum.map(fn {key, value} -> {to_string(key), encode(member, value)} end)
    |> Enum.reject(fn {_, value} -> is_nil(value) and not sparse? end)
    |> Map.new()
  end

  def encode({:structure, _, members}, value, _traits) do
    encode_members(members, value)
  end

  def encode({:union, _, members}, %Ash.Union{type: type, value: value}, _traits) do
    case Enum.find(members, &(&1.name == type)) do
      nil -> nil
      member -> %{json_name(member) => encode(member.descriptor, value, member.traits)}
    end
  end

  def encode({:union, _, _}, _value, _traits), do: nil

  @doc "Encodes the given members of a map or struct as a JSON object, omitting nil values."
  @spec encode_members([Member.t()], map) :: map
  def encode_members(members, value) do
    Enum.reduce(members, %{}, fn member, acc ->
      case fetch_field_or_default(value, member) do
        {:ok, field_value} ->
          case encode(member.descriptor, field_value, member.traits || %{}) do
            nil -> acc
            encoded -> Map.put(acc, json_name(member), encoded)
          end

        :error ->
          acc
      end
    end)
  end

  @doc """
  Fetches a member's value, falling back to its `@default`. Servers populate defaults for
  members that are missing from their output.
  """
  def fetch_field_or_default(value, member) do
    case fetch_field(value, member.name) do
      {:ok, nil} -> default(member)
      {:ok, field_value} -> {:ok, field_value}
      :error -> default(member)
    end
  end

  @doc """
  The value of a member's `@default` trait, or `:error` if it has none.
  """
  def default(member) do
    case Map.fetch(member.traits || %{}, "smithy.api#default") do
      # A null default removes the default of the target
      {:ok, nil} -> :error
      {:ok, default} -> {:ok, from_default(member.descriptor, default)}
      :error -> :error
    end
  end

  # Blob defaults are base64 encoded
  defp from_default(descriptor, value) do
    case unwrap(descriptor) do
      {:simple, "Blob", _} when is_binary(value) -> Base.decode64!(value)
      _ -> from_node(descriptor, value)
    end
  end

  @doc "The JSON key of a member."
  def json_name(%Member{} = member) do
    (member.traits || %{})["smithy.api#jsonName"] || member.member
  end

  @doc false
  def fetch_field(%{__struct__: _} = struct, field) do
    case Map.fetch(struct, field) do
      {:ok, %Ash.NotLoaded{}} -> :error
      {:ok, %Ash.ForbiddenField{}} -> :error
      {:ok, value} -> {:ok, value}
      :error -> :error
    end
  end

  def fetch_field(map, field) when is_map(map) do
    case Map.fetch(map, field) do
      {:ok, value} -> {:ok, value}
      :error when is_atom(field) -> Map.fetch(map, to_string(field))
      :error -> :error
    end
  end

  def fetch_field(_, _), do: :error

  @doc """
  Encodes a value as an HTTP header value. Returns `nil` if the header should not be sent.
  """
  @spec encode_header(AshSmithy.Type.descriptor(), term, map) :: String.t() | nil
  def encode_header(_descriptor, nil, _traits), do: nil

  def encode_header({:list, _, member, _}, values, _traits) do
    values
    |> Enum.reject(&is_nil/1)
    |> Enum.map_join(", ", fn value ->
      encoded = encode_header(member, value, %{})

      case member do
        {:simple, "Timestamp", _} ->
          encoded

        _ ->
          if String.contains?(encoded, [",", "\""]) do
            ~s(") <> String.replace(encoded, ~s("), ~s(\\")) <> ~s(")
          else
            encoded
          end
      end
    end)
  end

  def encode_header({:simple, "Timestamp", descriptor_traits}, value, traits) do
    format = timestamp_format(Map.merge(descriptor_traits, traits), :header)
    to_string(encode_timestamp(to_datetime(value), format))
  end

  def encode_header({:simple, "String", descriptor_traits}, value, traits) do
    if Map.has_key?(Map.merge(descriptor_traits, traits), "smithy.api#mediaType") do
      Base.encode64(to_string(value))
    else
      to_string(value)
    end
  end

  def encode_header(descriptor, value, traits) do
    case encode(descriptor, value, traits) do
      %Jason.Fragment{} = fragment -> IO.iodata_to_binary(fragment.encode.(nil))
      value when is_binary(value) -> value
      value -> to_string(value)
    end
  end

  defp encode_timestamp(%DateTime{} = datetime, "epoch-seconds") do
    case DateTime.to_unix(datetime, :microsecond) do
      micros when rem(micros, 1_000_000) == 0 -> div(micros, 1_000_000)
      micros -> Float.round(micros / 1_000_000, 3)
    end
  end

  defp encode_timestamp(%DateTime{} = datetime, "http-date") do
    datetime = DateTime.shift_zone!(datetime, "Etc/UTC")
    Calendar.strftime(datetime, "%a, %d %b %Y %H:%M:%S GMT")
  end

  defp encode_timestamp(%DateTime{} = datetime, _date_time) do
    datetime = DateTime.shift_zone!(datetime, "Etc/UTC")

    case datetime.microsecond do
      {0, _} -> datetime |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      _ -> DateTime.to_iso8601(datetime)
    end
  end

  defp encode_timestamp(value, _format), do: value

  defp to_datetime(%DateTime{} = value), do: value
  defp to_datetime(%NaiveDateTime{} = value), do: DateTime.from_naive!(value, "Etc/UTC")
  defp to_datetime(value), do: value

  defp encode_document(%Decimal{} = value), do: Decimal.to_float(value)
  defp encode_document(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp encode_document(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp encode_document(%Date{} = value), do: Date.to_iso8601(value)
  defp encode_document(%Time{} = value), do: Time.to_iso8601(value)

  defp encode_document(%{__struct__: _} = value) do
    value |> Map.from_struct() |> Map.delete(:__meta__) |> encode_document()
  end

  defp encode_document(value) when is_map(value) do
    Map.new(value, fn {key, value} -> {to_string(key), encode_document(value)} end)
  end

  defp encode_document(value) when is_list(value) do
    if value != [] and Keyword.keyword?(value) do
      value |> Map.new() |> encode_document()
    else
      Enum.map(value, &encode_document/1)
    end
  end

  defp encode_document(value) when is_atom(value) and not is_boolean(value) and not is_nil(value),
    do: to_string(value)

  defp encode_document(value), do: value

  ## Decoding JSON

  @doc """
  Decodes a JSON value from a body.

  JSON must be decoded with `floats: :decimals`, so that numbers keep their precision.
  """
  @spec decode(AshSmithy.Type.descriptor(), term, map) :: {:ok, term} | {:error, String.t()}
  def decode(descriptor, value, traits \\ %{})
  def decode(_descriptor, nil, _traits), do: {:ok, nil}

  def decode({:resource, resource}, value, traits) do
    decode(AshSmithy.Type.resource_structure(resource), value, traits)
  end

  def decode({:lazy, m, f, a}, value, traits), do: decode(apply(m, f, a), value, traits)
  def decode({:constrained, descriptor, _}, value, traits), do: decode(descriptor, value, traits)
  def decode({:simple, "Unit", _}, value, _traits) when is_map(value), do: {:ok, %{}}

  def decode({:simple, "String", _}, value, _traits) when is_binary(value), do: {:ok, value}
  def decode({:simple, "Boolean", _}, value, _traits) when is_boolean(value), do: {:ok, value}

  def decode({:simple, type, _}, value, _traits) when is_map_key(@int_ranges, type) do
    case value do
      value when is_integer(value) -> check_int_range(type, value)
      _ -> {:error, "expected an integer"}
    end
  end

  def decode({:simple, "BigInteger", _}, value, _traits) when is_integer(value), do: {:ok, value}

  def decode({:simple, type, _}, value, _traits) when type in @floats do
    case value do
      value when is_integer(value) -> {:ok, value / 1}
      %Decimal{} -> decimal_to_float(value)
      "NaN" -> {:ok, :nan}
      "Infinity" -> {:ok, :infinity}
      "-Infinity" -> {:ok, :negative_infinity}
      _ -> {:error, "expected a number"}
    end
  end

  def decode({:simple, "BigDecimal", _}, value, _traits) do
    case value do
      value when is_integer(value) -> {:ok, Decimal.new(value)}
      %Decimal{} -> {:ok, value}
      _ -> {:error, "expected a number"}
    end
  end

  def decode({:simple, "Timestamp", descriptor_traits}, value, traits) do
    case timestamp_format(Map.merge(descriptor_traits, traits), :body) do
      "epoch-seconds" ->
        case value do
          value when is_integer(value) -> parse_epoch(Decimal.new(value))
          %Decimal{} -> parse_epoch(value)
          _ -> {:error, "expected epoch seconds"}
        end

      format ->
        if is_binary(value),
          do: parse_timestamp(value, format),
          else: {:error, "expected a string"}
    end
  end

  def decode({:simple, "Blob", _}, value, _traits) when is_binary(value), do: decode_base64(value)

  def decode({:simple, "Document", _}, value, _traits), do: {:ok, decode_document(value)}
  def decode({:simple, type, _}, _value, _traits), do: {:error, "expected a #{type}"}

  def decode({:enum, _, _}, value, _traits) when is_binary(value), do: {:ok, value}
  def decode({:enum, _, _}, _, _traits), do: {:error, "expected a string"}

  def decode({:int_enum, _, _}, value, _traits) when is_integer(value),
    do: check_int_range("Integer", value)

  def decode({:int_enum, _, _}, _, _traits), do: {:error, "expected an integer"}

  def decode({:list, _, member, sparse?}, values, _traits) when is_list(values) do
    values
    |> Enum.with_index()
    |> reduce_ok([], fn {value, index}, acc ->
      case {value, sparse?} do
        {nil, false} ->
          {:error, "#{index}: null is not allowed in a dense list"}

        _ ->
          case decode(member, value) do
            {:ok, value} -> {:ok, [value | acc]}
            {:error, message} -> {:error, "#{index}: #{message}"}
          end
      end
    end)
    |> map_ok(&Enum.reverse/1)
  end

  def decode({:list, _, _, _}, _, _traits), do: {:error, "expected a list"}

  def decode({:map, _, key, member, sparse?}, value, _traits) when is_map(value) do
    reduce_ok(value, %{}, fn {map_key, value}, acc ->
      with {:ok, map_key} <- decode(key, map_key) do
        case {value, sparse?} do
          {nil, false} ->
            {:error, "#{map_key}: null is not allowed in a dense map"}

          _ ->
            case decode(member, value) do
              {:ok, decoded} -> {:ok, Map.put(acc, map_key, decoded)}
              {:error, message} -> {:error, "#{map_key}: #{message}"}
            end
        end
      end
    end)
  end

  def decode({:map, _, _, _, _}, _, _traits), do: {:error, "expected an object"}

  def decode({:structure, _, members}, value, _traits) when is_map(value) do
    decode_members(members, value)
  end

  def decode({:structure, _, _}, _, _traits), do: {:error, "expected an object"}

  def decode({:union, _, members}, value, _traits) when is_map(value) do
    value
    |> Map.delete("__type")
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> case do
      [{key, value}] ->
        case Enum.find(members, &(json_name(&1) == key)) do
          nil ->
            {:error, "unknown union member #{key}"}

          member ->
            with {:ok, decoded} <- decode(member.descriptor, value, member.traits || %{}) do
              {:ok, %Ash.Union{type: member.name, value: decoded}}
            end
        end

      _ ->
        {:error, "expected exactly one union member to be set"}
    end
  end

  def decode({:union, _, _}, _, _traits), do: {:error, "expected an object"}

  @doc "Decodes the given members from a JSON object, returning a map keyed by member name."
  @spec decode_members([Member.t()], map) :: {:ok, map} | {:error, String.t()}
  def decode_members(members, value) do
    reduce_ok(members, %{}, fn member, acc ->
      case Map.fetch(value, json_name(member)) do
        {:ok, field_value} when not is_nil(field_value) ->
          case decode(member.descriptor, field_value, member.traits || %{}) do
            {:ok, decoded} -> {:ok, Map.put(acc, member.name, decoded)}
            {:error, message} -> {:error, "#{member.member}: #{message}"}
          end

        # Missing members are populated with their defaults
        _ ->
          case default(member) do
            {:ok, default} -> {:ok, Map.put(acc, member.name, default)}
            :error -> {:ok, acc}
          end
      end
    end)
  end

  defp decode_document(%Decimal{} = value) do
    if Decimal.integer?(value), do: Decimal.to_integer(value), else: Decimal.to_float(value)
  end

  defp decode_document(value) when is_map(value) do
    Map.new(value, fn {key, value} -> {key, decode_document(value)} end)
  end

  defp decode_document(value) when is_list(value), do: Enum.map(value, &decode_document/1)
  defp decode_document(value), do: value

  ## Decoding strings (labels, query strings and headers)

  @doc """
  Decodes a value from an HTTP label, query string or header.

  Query string lists are given as lists of strings, header lists as a single comma separated string.
  """
  @spec decode_string(AshSmithy.Type.descriptor(), String.t() | [String.t()], location, map) ::
          {:ok, term} | {:error, String.t()}
  def decode_string(descriptor, value, location, traits \\ %{})

  def decode_string({:list, _, member, _}, values, location, _traits) do
    values =
      case {values, location} do
        {values, :header} -> split_header(Enum.join(List.wrap(values), ", "), member)
        {values, _} -> List.wrap(values)
      end

    values
    |> reduce_ok([], fn value, acc ->
      case decode_string(member, value, location) do
        {:ok, value} -> {:ok, [value | acc]}
        error -> error
      end
    end)
    |> map_ok(&Enum.reverse/1)
  end

  # Only the first value is used for non-list members bound to the query string
  def decode_string(descriptor, [value | _], location, traits),
    do: decode_string(descriptor, value, location, traits)

  def decode_string({:simple, "String", descriptor_traits}, value, location, traits) do
    if location == :header and
         Map.has_key?(Map.merge(descriptor_traits, traits), "smithy.api#mediaType") do
      decode_base64(value)
    else
      {:ok, value}
    end
  end

  def decode_string({:simple, type, _}, value, _location, _traits)
      when is_map_key(@int_ranges, type) do
    case Integer.parse(value) do
      {int, ""} -> check_int_range(type, int)
      _ -> {:error, "expected an integer"}
    end
  end

  def decode_string({:simple, "BigInteger", _}, value, _location, _traits) do
    case Integer.parse(value) do
      {int, ""} -> {:ok, int}
      _ -> {:error, "expected an integer"}
    end
  end

  def decode_string({:simple, type, _}, value, _location, _traits) when type in @floats do
    case value do
      "NaN" -> {:ok, :nan}
      "Infinity" -> {:ok, :infinity}
      "-Infinity" -> {:ok, :negative_infinity}
      value -> parse_float(value)
    end
  end

  def decode_string({:simple, "BigDecimal", _}, value, _location, _traits) do
    case Decimal.parse(value) do
      {decimal, ""} -> {:ok, decimal}
      _ -> {:error, "expected a number"}
    end
  end

  def decode_string({:simple, "Boolean", _}, "true", _location, _traits), do: {:ok, true}
  def decode_string({:simple, "Boolean", _}, "false", _location, _traits), do: {:ok, false}

  def decode_string({:simple, "Boolean", _}, _, _location, _traits),
    do: {:error, "expected true or false"}

  def decode_string({:simple, "Timestamp", descriptor_traits}, value, location, traits) do
    case timestamp_format(Map.merge(descriptor_traits, traits), location) do
      "epoch-seconds" ->
        case Decimal.parse(value) do
          {decimal, ""} -> parse_epoch(decimal)
          _ -> {:error, "expected epoch seconds"}
        end

      format ->
        parse_timestamp(value, format)
    end
  end

  def decode_string({:simple, "Blob", _}, value, _location, _traits), do: decode_base64(value)

  def decode_string({:enum, _, _}, value, _location, _traits), do: {:ok, value}

  def decode_string({:int_enum, _, _}, value, _location, _traits) do
    case Integer.parse(value) do
      {int, ""} -> check_int_range("Integer", int)
      _ -> {:error, "expected an integer"}
    end
  end

  def decode_string(_, _, _, _), do: {:error, "cannot be bound to a string"}

  # Splits a header list. Strings may be quoted, and http-date timestamps contain a comma
  # but are never quoted.
  defp split_header(value, {:simple, "Timestamp", traits}) do
    if timestamp_format(traits, :header) == "http-date" do
      value
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.chunk_every(2)
      |> Enum.map(&Enum.join(&1, ", "))
    else
      split_quoted(value)
    end
  end

  defp split_header(value, _member), do: split_quoted(value)

  defp split_quoted(value) do
    value
    |> do_split_quoted([], "", false)
    |> Enum.map(&String.trim/1)
    |> Enum.map(fn
      ~s(") <> rest = quoted ->
        if String.ends_with?(rest, ~s(")) do
          rest |> String.slice(0..-2//1) |> String.replace(~s(\\"), ~s("))
        else
          quoted
        end

      value ->
        value
    end)
  end

  defp do_split_quoted("", acc, current, _quoted?) do
    if String.trim(current) == "" and acc == [], do: [], else: Enum.reverse([current | acc])
  end

  defp do_split_quoted(~s(\\") <> rest, acc, current, true),
    do: do_split_quoted(rest, acc, current <> ~s(\\"), true)

  defp do_split_quoted(~s(") <> rest, acc, current, quoted?),
    do: do_split_quoted(rest, acc, current <> ~s("), not quoted?)

  defp do_split_quoted("," <> rest, acc, current, false),
    do: do_split_quoted(rest, [current | acc], "", false)

  defp do_split_quoted(<<char::utf8, rest::binary>>, acc, current, quoted?),
    do: do_split_quoted(rest, acc, current <> <<char::utf8>>, quoted?)

  ## Node values

  @doc """
  Converts a Smithy node value, as used in `@default` traits, to an Elixir value.
  """
  @spec from_node(AshSmithy.Type.descriptor(), term) :: term
  def from_node(_descriptor, nil), do: nil

  def from_node({:resource, resource}, value),
    do: from_node(AshSmithy.Type.resource_structure(resource), value)

  def from_node({:lazy, m, f, a}, value), do: from_node(apply(m, f, a), value)
  def from_node({:constrained, descriptor, _}, value), do: from_node(descriptor, value)

  def from_node({:simple, "Timestamp", _}, value) when is_integer(value) do
    {:ok, datetime} = parse_epoch(Decimal.new(value))
    datetime
  end

  def from_node({:simple, "Timestamp", _}, value) when is_float(value) do
    {:ok, datetime} = parse_epoch(Decimal.from_float(value))
    datetime
  end

  def from_node({:simple, "Timestamp", _}, value) when is_binary(value) do
    {:ok, datetime} = parse_timestamp(value, "date-time")
    datetime
  end

  def from_node({:simple, "BigDecimal", _}, value) when is_number(value),
    do: Decimal.new(to_string(value))

  def from_node({:simple, type, _}, value) when type in @floats do
    case value do
      "NaN" -> :nan
      "Infinity" -> :infinity
      "-Infinity" -> :negative_infinity
      value -> value / 1
    end
  end

  def from_node({:list, _, member, _}, values), do: Enum.map(values, &from_node(member, &1))

  def from_node({:map, _, _, member, _}, values),
    do: Map.new(values, fn {key, value} -> {key, from_node(member, value)} end)

  def from_node({:structure, _, members}, value) do
    Enum.reduce(members, %{}, fn member, acc ->
      case Map.fetch(value, member.member) do
        {:ok, field_value} -> Map.put(acc, member.name, from_node(member.descriptor, field_value))
        :error -> acc
      end
    end)
  end

  def from_node({:union, _, members}, value) do
    [{key, value}] = Map.to_list(value)
    member = Enum.find(members, &(&1.member == key))
    %Ash.Union{type: member.name, value: from_node(member.descriptor, value)}
  end

  def from_node(_descriptor, value), do: value

  ## Helpers

  defp check_int_range(type, value) do
    {min, max} = Map.fetch!(@int_ranges, type)

    if value >= min and value <= max do
      {:ok, value}
    else
      {:error, "#{value} is out of range for a #{type}"}
    end
  end

  defp decimal_to_float(decimal) do
    {:ok, Decimal.to_float(decimal)}
  rescue
    _ -> {:error, "number is out of range"}
  end

  defp parse_float(value) do
    case Float.parse(value) do
      {float, ""} ->
        {:ok, float}

      _ ->
        case Integer.parse(value) do
          {int, ""} -> {:ok, int / 1}
          _ -> {:error, "expected a number"}
        end
    end
  end

  defp parse_epoch(%Decimal{coef: coef}) when coef in [:inf, :NaN],
    do: {:error, "invalid epoch timestamp"}

  defp parse_epoch(%Decimal{} = seconds) do
    micros = seconds |> Decimal.mult(1_000_000) |> Decimal.round(0, :down) |> Decimal.to_integer()

    case DateTime.from_unix(micros, :microsecond) do
      {:ok, datetime} -> {:ok, datetime}
      {:error, _} -> {:error, "invalid epoch timestamp"}
    end
  end

  @doc false
  def parse_timestamp(value, "date-time") do
    # Smithy's date-time is RFC 3339 without UTC offsets
    if String.match?(value, ~r/^\d{4}-\d{2}-\d{2}[Tt]\d{2}:\d{2}:\d{2}(\.\d+)?[Zz]$/) do
      case DateTime.from_iso8601(String.upcase(value)) do
        {:ok, datetime, _offset} -> {:ok, datetime}
        {:error, _} -> {:error, "expected an RFC 3339 date-time"}
      end
    else
      {:error, "expected an RFC 3339 date-time"}
    end
  end

  @months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)
  @days ~w(Mon Tue Wed Thu Fri Sat Sun)

  def parse_timestamp(value, "http-date") do
    regex = ~r/^(\w{3}), (\d{2}) (\w{3}) (\d{4}) (\d{2}):(\d{2}):(\d{2})(\.\d+)? GMT$/

    # The optional fraction group is dropped from the captures when it doesn't match
    with [_, day, date, month, year, hour, minute, second | fraction] <- Regex.run(regex, value),
         fraction = List.first(fraction, ""),
         true <- day in @days,
         month when not is_nil(month) <- Enum.find_index(@months, &(&1 == month)),
         {:ok, naive} <-
           NaiveDateTime.new(
             String.to_integer(year),
             month + 1,
             String.to_integer(date),
             String.to_integer(hour),
             String.to_integer(minute),
             String.to_integer(second)
           ) do
      datetime = DateTime.from_naive!(naive, "Etc/UTC")

      case fraction do
        "" ->
          {:ok, datetime}

        "." <> digits ->
          micros =
            digits |> String.pad_trailing(6, "0") |> String.slice(0, 6) |> String.to_integer()

          {:ok, %{datetime | microsecond: {micros, 6}}}
      end
    else
      _ -> {:error, "expected an HTTP date"}
    end
  end

  defp decode_base64(value) do
    case Base.decode64(value) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> {:error, "expected base64 encoded data"}
    end
  end

  defp reduce_ok(enumerable, acc, fun) do
    Enum.reduce_while(enumerable, {:ok, acc}, fn item, {:ok, acc} ->
      case fun.(item, acc) do
        {:ok, acc} -> {:cont, {:ok, acc}}
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
  end

  defp map_ok({:ok, value}, fun), do: {:ok, fun.(value)}
  defp map_ok(error, _fun), do: error
end
