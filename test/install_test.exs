defmodule AshSmithy.InstallTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  test "creates a router for the domains using AshSmithy.Domain" do
    test_project()
    |> Igniter.create_new_file("lib/test/helpdesk.ex", """
    defmodule Test.Helpdesk do
      use Ash.Domain, extensions: [AshSmithy.Domain]

      resources do
      end
    end
    """)
    |> Igniter.create_new_file("lib/test/billing.ex", """
    defmodule Test.Billing do
      use Ash.Domain

      resources do
      end
    end
    """)
    |> Igniter.compose_task("ash_smithy.install", [])
    |> assert_creates("lib/test_web/smithy_router.ex", """
    defmodule TestWeb.SmithyRouter do
      use AshSmithy.Router,
        domains: [Test.Helpdesk],
        model: "/model.json"
    end
    """)
    |> assert_has_patch(".formatter.exs", """
    + |  import_deps: [:ash_smithy]
    """)
  end

  test "leaves an existing router alone" do
    test_project(
      files: %{
        "lib/test_web/smithy_router.ex" => """
        defmodule TestWeb.SmithyRouter do
          use AshSmithy.Router, domains: [Test.Helpdesk]
        end
        """
      }
    )
    |> Igniter.compose_task("ash_smithy.install", [])
    |> assert_unchanged("lib/test_web/smithy_router.ex")
  end

  test "forwards to the router from the Phoenix router" do
    phx_test_project()
    |> Igniter.compose_task("ash_smithy.install", [])
    |> assert_has_patch("lib/test_web/router.ex", """
    + |  scope "/api/smithy" do
    + |    pipe_through([:api])
    + |
    + |    forward("/", TestWeb.SmithyRouter)
    + |  end
    """)
  end
end
