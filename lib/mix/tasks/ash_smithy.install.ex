if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.AshSmithy.Install do
    @shortdoc "Installs AshSmithy. Should be run with `mix igniter.install ash_smithy`"

    @moduledoc """
    #{@shortdoc}.

    * Imports the `ash_smithy` formatter rules.
    * Puts the `smithy` section first in resources and domains.
    * Creates a router serving every domain that uses `AshSmithy.Domain`, along with the
      Smithy model of those domains at `/model.json`.
    * Forwards to that router from your Phoenix router, if you have one.

    ## Options

    * `--path` - where to mount the router in your Phoenix router. Defaults to `/api/smithy`.
    """

    use Igniter.Mix.Task

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :ash,
        schema: [path: :string],
        defaults: [path: "/api/smithy"]
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      router = Igniter.Libs.Phoenix.web_module_name(igniter, "SmithyRouter")

      igniter
      |> Igniter.Project.Formatter.import_dep(:ash_smithy)
      |> Spark.Igniter.prepend_to_section_order(:"Ash.Resource", [:smithy])
      |> Spark.Igniter.prepend_to_section_order(:"Ash.Domain", [:smithy])
      |> setup_router(router)
      |> setup_phoenix(router, igniter.args.options[:path])
    end

    defp setup_router(igniter, router) do
      {igniter, domains} = Ash.Domain.Igniter.list_domains(igniter)

      {igniter, domains} =
        Enum.reduce(domains, {igniter, []}, fn domain, {igniter, domains} ->
          case smithy_domain?(igniter, domain) do
            {igniter, true} -> {igniter, [domain | domains]}
            {igniter, false} -> {igniter, domains}
          end
        end)

      {exists?, igniter} = Igniter.Project.Module.module_exists(igniter, router)

      if exists? do
        Igniter.add_notice(igniter, "#{inspect(router)} already exists, leaving it as it is.")
      else
        Igniter.Project.Module.create_module(igniter, router, """
        use AshSmithy.Router,
          domains: #{inspect(Enum.reverse(domains))},
          model: "/model.json"
        """)
      end
    end

    defp smithy_domain?(igniter, domain) do
      case Igniter.Project.Module.find_module(igniter, domain) do
        {:ok, {igniter, _source, zipper}} ->
          with {:ok, zipper} <-
                 Igniter.Code.Function.move_to_function_call(
                   zipper,
                   :use,
                   2,
                   &Igniter.Code.Function.argument_equals?(&1, 0, Ash.Domain)
                 ),
               {:ok, zipper} <- Igniter.Code.Function.move_to_nth_argument(zipper, 1),
               {:ok, zipper} <- Igniter.Code.Keyword.get_key(zipper, :extensions) do
            {igniter, extension?(zipper)}
          else
            _ -> {igniter, false}
          end

        {:error, igniter} ->
          {igniter, false}
      end
    end

    defp extension?(zipper) do
      if Igniter.Code.List.list?(zipper) do
        match?(
          {:ok, _},
          Igniter.Code.List.move_to_list_item(
            zipper,
            &Igniter.Code.Common.nodes_equal?(&1, AshSmithy.Domain)
          )
        )
      else
        Igniter.Code.Common.nodes_equal?(zipper, AshSmithy.Domain)
      end
    end

    defp setup_phoenix(igniter, router, path) do
      case Igniter.Libs.Phoenix.select_router(igniter) do
        {igniter, nil} ->
          Igniter.add_notice(igniter, """
          No Phoenix router found. To serve your Smithy services, forward to #{inspect(router)}
          from your router or endpoint, e.g.

              forward "#{path}", #{inspect(router)}
          """)

        {igniter, phoenix_router} ->
          igniter
          |> Igniter.Libs.Phoenix.add_pipeline(:api, "plug :accepts, [\"json\"]",
            router: phoenix_router,
            warn_on_present?: false
          )
          |> Igniter.Libs.Phoenix.add_scope(
            path,
            """
            pipe_through [:api]

            forward "/", #{inspect(router)}
            """,
            router: phoenix_router
          )
      end
    end
  end
else
  defmodule Mix.Tasks.AshSmithy.Install do
    @shortdoc "Installs AshSmithy. Should be run with `mix igniter.install ash_smithy`"

    @moduledoc @shortdoc

    use Mix.Task

    def run(_argv) do
      Mix.shell().error("""
      The task 'ash_smithy.install' requires igniter to be run.

      Please install igniter and try again.

      For more information, see: https://hexdocs.pm/igniter
      """)

      exit({:shutdown, 1})
    end
  end
end
