defmodule AshSmithy.Validation do
  @moduledoc """
  Validates decoded input against Smithy constraint traits (`@required`, `@length`, `@range`,
  `@pattern`, `@uniqueItems` and enum values), producing the messages Smithy servers use for
  `ValidationException`s.

  Paths are JSON pointers built from member names.
  """

  alias AshSmithy.Codec
  alias AshSmithy.Type.Member

  @type error :: {path :: String.t(), message :: String.t()}

  @doc "Validates a map of decoded values, keyed by member name, against the given members."
  @spec validate_members([Member.t()], map, String.t()) :: [error]
  def validate_members(members, values, path \\ "") do
    Enum.flat_map(members, fn member ->
      member_path = path <> "/" <> member.member

      case Map.fetch(values, member.name) do
        {:ok, value} when not is_nil(value) ->
          validate(member.descriptor, Codec.traits(member), value, member_path)

        _ ->
          if member.required? do
            [
              {member_path,
               "Value at '#{member_path}' failed to satisfy constraint: Member must not be null"}
            ]
          else
            []
          end
      end
    end)
  end

  @doc "Formats the message of a `ValidationException`."
  @spec message([error]) :: String.t()
  def message([{_, message}]), do: "1 validation error detected. " <> message

  def message(errors) do
    "#{Enum.count(errors)} validation errors detected. " <>
      Enum.map_join(errors, "; ", fn {_, message} -> message end)
  end

  defp validate({:resource, resource}, traits, value, path) do
    validate(AshSmithy.Type.resource_structure(resource), traits, value, path)
  end

  defp validate({:lazy, m, f, a}, traits, value, path) do
    validate(apply(m, f, a), traits, value, path)
  end

  defp validate({:constrained, descriptor, constraints}, traits, value, path) do
    validate(descriptor, Map.merge(constraints, traits), value, path)
  end

  defp validate(descriptor, traits, value, path) do
    own =
      [
        length_error(traits, value, path),
        range_error(traits, value, path),
        pattern_error(traits, value, path),
        enum_error(descriptor, value, path),
        unique_error(traits, value, path)
      ]
      |> Enum.reject(&is_nil/1)

    own ++ nested(descriptor, value, path)
  end

  defp nested({:list, _, member, _}, values, path) do
    values
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {nil, _} ->
        []

      {value, index} ->
        validate(member, Codec.descriptor_traits(member), value, "#{path}/#{index}")
    end)
  end

  defp nested({:map, _, key, member, _}, values, path) do
    Enum.flat_map(values, fn {map_key, value} ->
      # Constraints on keys are reported at the map itself
      key_errors = validate(key, Codec.descriptor_traits(key), map_key, path)

      value_errors =
        if is_nil(value),
          do: [],
          else: validate(member, Codec.descriptor_traits(member), value, "#{path}/#{map_key}")

      key_errors ++ value_errors
    end)
  end

  defp nested({:structure, _, members}, value, path) when is_map(value) do
    validate_members(members, value, path)
  end

  defp nested({:union, _, members}, %Ash.Union{type: type, value: value}, path) do
    case Enum.find(members, &(&1.name == type)) do
      nil ->
        []

      member ->
        validate(member.descriptor, Codec.traits(member), value, path <> "/" <> member.member)
    end
  end

  defp nested(_descriptor, _value, _path), do: []

  defp length_error(%{"smithy.api#length" => length}, value, path) do
    case length_of(value) do
      nil ->
        nil

      count ->
        min = length["min"]
        max = length["max"]

        if (min && count < min) || (max && count > max) do
          "Value with length #{count} at '#{path}' failed to satisfy constraint: Member must have length #{bounds(min, max)}"
        end
    end
    |> to_error(path)
  end

  defp length_error(_, _, _), do: nil

  defp length_of(value) when is_binary(value) do
    if String.valid?(value), do: length(String.codepoints(value)), else: byte_size(value)
  end

  defp length_of(value) when is_list(value), do: length(value)
  defp length_of(value) when is_map(value) and not is_struct(value), do: map_size(value)
  defp length_of(_), do: nil

  defp range_error(%{"smithy.api#range" => range}, value, path) do
    case comparable(value) do
      nil ->
        nil

      number ->
        min = range["min"]
        max = range["max"]

        if (min && Decimal.lt?(number, decimal(min))) ||
             (max && Decimal.gt?(number, decimal(max))) do
          "Value at '#{path}' failed to satisfy constraint: Member must be #{range_bounds(min, max)}"
        end
    end
    |> to_error(path)
  end

  defp range_error(_, _, _), do: nil

  defp comparable(value) when is_integer(value), do: Decimal.new(value)
  defp comparable(value) when is_float(value), do: Decimal.from_float(value)
  defp comparable(%Decimal{} = value), do: value
  defp comparable(_), do: nil

  defp decimal(value) when is_integer(value), do: Decimal.new(value)
  defp decimal(value) when is_float(value), do: Decimal.from_float(value)
  defp decimal(value) when is_binary(value), do: Decimal.new(value)

  defp pattern_error(%{"smithy.api#pattern" => pattern}, value, path) when is_binary(value) do
    case Regex.compile(pattern, "u") do
      {:ok, regex} ->
        unless Regex.match?(regex, value) do
          "Value at '#{path}' failed to satisfy constraint: Member must satisfy regular expression pattern: #{pattern}"
        end

      {:error, _} ->
        nil
    end
    |> to_error(path)
  end

  defp pattern_error(_, _, _), do: nil

  defp enum_error({:enum, _, values}, value, path) when is_binary(value) do
    allowed = Enum.map(values, &elem(&1, 1))

    unless value in allowed do
      "Value at '#{path}' failed to satisfy constraint: Member must satisfy enum value set: [#{Enum.join(public_values(values), ", ")}]"
    end
    |> to_error(path)
  end

  defp enum_error({:int_enum, _, values}, value, path) when is_integer(value) do
    allowed = Enum.map(values, &elem(&1, 1))

    unless value in allowed do
      "Value at '#{path}' failed to satisfy constraint: Member must satisfy enum value set: [#{Enum.join(allowed, ", ")}]"
    end
    |> to_error(path)
  end

  defp enum_error(_, _, _), do: nil

  # Enum values tagged `internal` are not included in messages
  defp public_values(values) do
    for value <- values, not match?({_, _, :internal}, value), do: elem(value, 1)
  end

  defp unique_error(%{"smithy.api#uniqueItems" => _}, values, path) when is_list(values) do
    if Enum.uniq(values) != values do
      "Value at '#{path}' failed to satisfy constraint: Member must have unique values"
    end
    |> to_error(path)
  end

  defp unique_error(_, _, _), do: nil

  defp bounds(min, nil), do: "greater than or equal to #{format_number(min)}"
  defp bounds(nil, max), do: "less than or equal to #{format_number(max)}"
  defp bounds(min, max), do: "between #{format_number(min)} and #{format_number(max)}, inclusive"

  defp range_bounds(min, max), do: bounds(min, max)

  defp format_number(value) when is_float(value) do
    if value == Float.round(value), do: to_string(trunc(value)), else: to_string(value)
  end

  defp format_number(value), do: to_string(value)

  defp to_error(nil, _path), do: nil
  defp to_error(message, path), do: {path, message}
end
