defmodule AshSmithy.Idl do
  @moduledoc """
  Renders a Smithy JSON AST (as built by `AshSmithy.Model.build/1`) as
  [Smithy IDL](https://smithy.io/2.0/spec/idl.html).

  The AST is the source of truth: the IDL is a different serialization of the same model.
  """

  @prelude "smithy.api"

  # Traits rendered first on members, in this order, for readability.
  @trait_order [
    "smithy.api#required",
    "smithy.api#resourceIdentifier",
    "smithy.api#httpLabel",
    "smithy.api#httpQuery",
    "smithy.api#httpHeader"
  ]

  @doc "Renders the Smithy IDL for the given domain or domains."
  @spec render(Ash.Domain.t() | [Ash.Domain.t()]) :: String.t()
  def render(domains) do
    domains
    |> AshSmithy.Model.build()
    |> from_ast()
  end

  @doc """
  Renders a JSON AST map as Smithy IDL.

  All shapes must be in a single namespace.
  """
  @spec from_ast(map) :: String.t()
  def from_ast(%{"shapes" => shapes}) do
    namespaces = shapes |> Map.keys() |> Enum.map(&namespace/1) |> Enum.uniq()

    ns =
      case namespaces do
        [ns] ->
          ns

        namespaces ->
          raise ArgumentError, "Expected a single namespace, got: #{inspect(namespaces)}"
      end

    uses =
      shapes
      |> Enum.flat_map(fn {_id, shape} -> shape_references(shape) end)
      |> Enum.reject(&(namespace(&1) in [ns, @prelude]))
      |> Enum.uniq()
      |> Enum.sort()

    header =
      [
        ~s($version: "2"),
        "",
        "namespace #{ns}",
        ""
      ] ++
        if uses == [] do
          []
        else
          Enum.map(uses, &"use #{&1}") ++ [""]
        end

    body =
      shapes
      |> Enum.sort_by(&sort_key(&1, shapes))
      |> Enum.map_join("\n\n", fn {id, shape} -> render_shape(ns, uses, id, shape) end)

    Enum.join(header, "\n") <> "\n" <> body <> "\n"
  end

  # Shapes are ordered service, resources, then each operation followed by its input and
  # output, then other shapes, then errors.
  defp sort_key({id, shape}, shapes) do
    case shape["type"] do
      "service" ->
        {0, id, 0}

      "resource" ->
        {1, id, 0}

      "operation" ->
        {2, id, 0}

      _ ->
        base = id |> String.replace_suffix("Input", "") |> String.replace_suffix("Output", "")

        cond do
          base != id and match?(%{"type" => "operation"}, shapes[base]) ->
            {2, base, if(String.ends_with?(id, "Input"), do: 1, else: 2)}

          Map.has_key?(shape["traits"] || %{}, "smithy.api#error") or
              String.ends_with?(id, ["ValidationExceptionField", "ValidationExceptionFieldList"]) ->
            {4, id, 0}

          true ->
            {3, id, 0}
        end
    end
  end

  defp render_shape(ns, uses, id, shape) do
    name = name(id)
    traits = render_traits(ns, uses, shape["traits"], "")

    body =
      case shape["type"] do
        type when type in ["structure", "union"] ->
          case Map.get(shape, "members", %{}) do
            members when map_size(members) == 0 -> ["#{type} #{name} {}"]
            members -> ["#{type} #{name} {"] ++ render_members(ns, uses, members) ++ ["}"]
          end

        "enum" ->
          ["enum #{name} {"] ++
            Enum.map(shape["members"], fn {member, %{"traits" => traits}} ->
              "    #{member} = #{value(traits["smithy.api#enumValue"])}"
            end) ++ ["}"]

        "list" ->
          ["list #{name} {"] ++
            render_members(ns, uses, %{"member" => shape["member"]}) ++ ["}"]

        "map" ->
          ["map #{name} {"] ++
            render_members(ns, uses, %{"key" => shape["key"], "value" => shape["value"]}) ++
            ["}"]

        type when type in ["service", "resource", "operation"] ->
          properties =
            shape
            |> Map.drop(["type", "traits"])
            |> Enum.sort_by(fn {key, _} -> key end)
            |> Enum.map(fn {key, value} -> "    #{key}: #{shape_value(ns, uses, value)}" end)

          ["#{type} #{name} {"] ++ properties ++ ["}"]

        type ->
          ["#{type} #{name}"]
      end

    Enum.join(traits ++ body, "\n")
  end

  defp shape_value(_ns, _uses, value) when is_binary(value), do: value(value)

  defp shape_value(ns, uses, values) when is_list(values) do
    "[" <> Enum.map_join(values, ", ", &shape_id(ns, uses, &1["target"])) <> "]"
  end

  defp shape_value(ns, uses, %{"target" => target}), do: shape_id(ns, uses, target)

  defp shape_value(ns, uses, map) when is_map(map) do
    entries =
      map
      |> Enum.sort_by(fn {key, _} -> key end)
      |> Enum.map_join(", ", fn {key, %{"target" => target}} ->
        "#{key}: #{shape_id(ns, uses, target)}"
      end)

    "{ " <> entries <> " }"
  end

  defp render_members(ns, uses, members) do
    members
    |> Enum.sort_by(fn {name, _} -> name end)
    |> Enum.with_index()
    |> Enum.flat_map(fn {{name, member}, index} ->
      traits = render_traits(ns, uses, member["traits"], "    ")
      # Separate members that have traits from the previous member for readability
      spacer = if index > 0 and traits != [], do: [""], else: []
      spacer ++ traits ++ ["    #{name}: #{shape_id(ns, uses, member["target"])}"]
    end)
  end

  defp render_traits(_ns, _uses, nil, _indent), do: []

  defp render_traits(ns, uses, traits, indent) do
    {docs, traits} = Map.pop(traits, "smithy.api#documentation")

    doc_lines =
      case docs do
        nil ->
          []

        docs ->
          docs
          |> String.split("\n")
          |> Enum.map(&String.trim_trailing("#{indent}/// #{&1}"))
      end

    trait_lines =
      traits
      |> Enum.sort_by(fn {id, _} ->
        {Enum.find_index(@trait_order, &(&1 == id)) || length(@trait_order), id}
      end)
      |> Enum.map(fn {id, value} -> indent <> "@" <> trait(ns, uses, id, value) end)

    doc_lines ++ trait_lines
  end

  defp trait(ns, uses, id, value) do
    name = shape_id(ns, uses, id)

    case value do
      empty when empty == %{} ->
        name

      map when is_map(map) ->
        args =
          map
          |> Enum.sort_by(fn {key, _} -> key end)
          |> Enum.map_join(", ", fn {key, value} -> "#{key}: #{value(value)}" end)

        "#{name}(#{args})"

      value ->
        "#{name}(#{value(value)})"
    end
  end

  # Node values
  defp value(value) when is_binary(value), do: Jason.encode!(value)
  defp value(value) when is_boolean(value), do: to_string(value)
  defp value(nil), do: "null"
  defp value(value) when is_number(value), do: Jason.encode!(value)

  defp value(values) when is_list(values) do
    "[" <> Enum.map_join(values, ", ", &value/1) <> "]"
  end

  defp value(map) when is_map(map) do
    entries =
      map
      |> Enum.sort_by(fn {key, _} -> key end)
      |> Enum.map_join(", ", fn {key, value} -> "#{key}: #{value(value)}" end)

    "{ " <> entries <> " }"
  end

  defp shape_id(ns, uses, id) do
    if namespace(id) in [ns, @prelude] or id in uses do
      name(id)
    else
      id
    end
  end

  # Shape IDs referenced outside of the local namespace, so they can be imported with `use`.
  defp shape_references(shape) do
    trait_ids = Map.keys(shape["traits"] || %{})

    member_trait_ids =
      shape
      |> Map.take(["members", "member", "key", "value"])
      |> Enum.flat_map(fn
        {"members", members} -> Map.values(members)
        {_, member} -> [member]
      end)
      |> Enum.flat_map(&Map.keys(&1["traits"] || %{}))

    trait_ids ++ member_trait_ids
  end

  defp namespace(id), do: id |> String.split("#") |> hd()
  defp name(id), do: id |> String.split("#") |> List.last()
end
