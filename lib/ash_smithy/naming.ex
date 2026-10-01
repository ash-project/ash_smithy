defmodule AshSmithy.Naming do
  @moduledoc false

  @doc "Converts a field or argument name to a lowerCamelCase member name."
  def member_name(name) do
    case name
         |> to_string()
         |> String.trim_trailing("?")
         |> String.trim_trailing("!")
         |> Macro.camelize() do
      <<first::utf8, rest::binary>> -> String.downcase(<<first::utf8>>) <> rest
      "" -> ""
    end
  end

  @doc "Converts a name to an UpperCamelCase shape name."
  def shape_name(name) do
    name
    |> to_string()
    |> String.trim_trailing("?")
    |> String.trim_trailing("!")
    |> Macro.camelize()
  end

  @doc "Converts an UpperCamelCase name to dash-case."
  def dasherize(name) do
    name |> Macro.underscore() |> String.replace("_", "-")
  end

  @doc "A naive english pluralization."
  def pluralize(name) do
    cond do
      String.ends_with?(name, ["s", "x", "z", "ch", "sh"]) ->
        name <> "es"

      String.match?(name, ~r/[^aeiouAEIOU]y$/) ->
        String.slice(name, 0..-2//1) <> "ies"

      true ->
        name <> "s"
    end
  end
end
