defmodule Mix.Tasks.AshSmithy.Codegen do
  @shortdoc "Generates Smithy models for domains using AshSmithy.Domain"

  @moduledoc """
  #{@shortdoc}.

  Also runs as part of `mix ash.codegen`.

  Writes one model file per domain to `<output>/model/`, along with a `smithy-build.json`
  that can be used with the [Smithy CLI](https://smithy.io/2.0/guides/smithy-cli/index.html),
  e.g. to validate the model or generate clients:

      mix ash_smithy.codegen
      cd priv/smithy && smithy build

  Domains are discovered from the `:ash_domains` config of your otp app.

  ## Formats

  Models can be written as [Smithy IDL](https://smithy.io/2.0/spec/idl.html) (`.smithy`)
  and/or as the [JSON AST](https://smithy.io/2.0/spec/json-ast.html) (`.json`). Both describe
  the same model, and Smithy refuses to load the same shape from two files, so when both
  formats are generated only the IDL is written to `<output>/model/` and the JSON AST is written
  to `<output>/ast/`.

  ## Configuration

      config :ash_smithy,
        output: "priv/smithy",
        formats: [:idl]

  ## Options

    * `--output` - the directory to write to. Defaults to the `:output` config, or `priv/smithy`.
    * `--format` - `idl`, `json` or `idl,json`. Defaults to the `:formats` config, or `idl`.
    * `--domains` - a comma separated list of domains to generate models for.
    * `--check` - instead of writing files, raise an error if they are out of date.
    * `--dry-run` - print the files that would change instead of writing them.
  """

  use Mix.Task

  @smithy_version "1.74.0"

  @impl true
  def run(args) do
    Mix.Task.run("compile")

    # Parse leniently, `mix ash.codegen` passes through flags meant for other extensions
    {opts, _, _} =
      OptionParser.parse(args,
        switches: [
          output: :string,
          format: :string,
          domains: :string,
          check: :boolean,
          dry_run: :boolean
        ]
      )

    output = opts[:output] || Application.get_env(:ash_smithy, :output, "priv/smithy")
    formats = formats(opts)

    changed =
      opts
      |> domains()
      |> Enum.flat_map(&domain_files(&1, output, formats))
      |> Enum.concat([{Path.join(output, "smithy-build.json"), smithy_build()}])
      |> Enum.reject(fn {path, contents} ->
        File.read(path) == {:ok, contents} or
          (Path.basename(path) == "smithy-build.json" and File.exists?(path))
      end)

    cond do
      opts[:check] ->
        if changed != [] do
          raise Ash.Error.Framework.PendingCodegen, diff: Map.new(changed)
        end

      opts[:dry_run] ->
        Enum.each(changed, fn {path, contents} -> Mix.shell().info("# #{path}\n\n#{contents}") end)

      true ->
        Enum.each(changed, fn {path, contents} ->
          File.mkdir_p!(Path.dirname(path))
          File.write!(path, contents)
          Mix.shell().info("* writing #{path}")
        end)
    end
  end

  defp domain_files(domain, output, formats) do
    name = file_name(domain)

    Enum.map(formats, fn
      :idl ->
        {Path.join([output, "model", name <> ".smithy"]), AshSmithy.Idl.render(domain)}

      :json ->
        dir = if :idl in formats, do: "ast", else: "model"
        {Path.join([output, dir, name <> ".json"]), AshSmithy.Model.to_json(domain) <> "\n"}
    end)
  end

  defp formats(opts) do
    formats =
      case opts[:format] do
        nil ->
          Application.get_env(:ash_smithy, :formats, [:idl])

        formats ->
          formats |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
      end

    Enum.map(formats, fn
      format when format in [:idl, "idl"] -> :idl
      format when format in [:json, "json"] -> :json
      format -> Mix.raise("Unknown Smithy model format #{inspect(format)}, expected idl or json")
    end)
  end

  defp domains(opts) do
    case opts[:domains] do
      nil ->
        Mix.Project.config()[:app]
        |> Application.get_env(:ash_domains, [])
        |> Enum.filter(&(AshSmithy.Domain in Spark.extensions(&1)))

      domains ->
        domains
        |> String.split(",", trim: true)
        |> Enum.map(&Module.concat([String.trim(&1)]))
    end
  end

  defp file_name(domain) do
    domain |> Module.split() |> Enum.map_join("_", &Macro.underscore/1)
  end

  defp smithy_build do
    Jason.encode!(
      Jason.OrderedObject.new([
        {"version", "1.0"},
        {"sources", ["model"]},
        {"maven",
         Jason.OrderedObject.new([
           {"dependencies", ["software.amazon.smithy:smithy-aws-traits:#{@smithy_version}"]}
         ])}
      ]),
      pretty: true
    ) <> "\n"
  end
end
