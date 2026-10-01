# AshSmithy

> [!WARNING]
> AshSmithy was created agentically, modelled on other Ash extensions such as
> AshJsonApi and AshGraphql. It is an early experiment in compatibility with
> [Smithy](https://smithy.io), and has not yet been used in production.
>
> The server is tested against the official Smithy protocol compliance tests for
> `aws.protocols#restJson1`, from `software.amazon.smithy:smithy-aws-protocol-tests`.
> It passes 832 of the 880 test cases (request, response, error and malformed request
> cases). The other 48 are skipped because they rely on traits AshSmithy never generates:
> `@httpPayload` (44), `@endpoint` (2) and `@requestCompression` (2).

AshSmithy generates [Smithy](https://smithy.io) models from your Ash resources, and serves
them over Smithy protocols. Currently that is `restJson1`.

Describe which actions to expose, and AshSmithy builds the Smithy service, resources,
operations and shapes from your resources' attributes, arguments, types and constraints. The
generated model can be used with the Smithy toolchain, e.g. to validate it or to generate
clients in other languages.

## Installation

With [Igniter](https://hexdocs.pm/igniter):

```sh
mix igniter.install ash_smithy
```

This adds the dependency and formatter rules, creates a `SmithyRouter` for your domains, and
mounts it at `/api/smithy` in your Phoenix router.

Or add it to your dependencies yourself:

```elixir
def deps do
  [
    {:ash_smithy, "~> 0.1.0"}
  ]
end
```

## Usage

Add `AshSmithy.Domain` to a domain, to expose it as a Smithy service:

```elixir
defmodule MyApp.Helpdesk do
  use Ash.Domain, extensions: [AshSmithy.Domain]

  smithy do
    namespace "com.example.helpdesk"
    version "2026-10-01"
    title "Helpdesk Service"
  end

  resources do
    resource MyApp.Helpdesk.Ticket
  end
end
```

Then add `AshSmithy.Resource` to its resources, and choose the operations to expose:

```elixir
defmodule MyApp.Helpdesk.Ticket do
  use Ash.Resource,
    domain: MyApp.Helpdesk,
    extensions: [AshSmithy.Resource]

  smithy do
    relationships([:representative])

    operations do
      create :open
      read :read
      update :update
      delete :destroy, idempotent?: true
      list :read
      operation :close
      collection_operation :search
    end
  end

  # ...
end
```

`create`, `read`, `update`, `delete` and `list` become the Smithy resource's lifecycle
operations. `operation` binds any other action to a single record, and `collection_operation`
binds one to the collection. List operations are paginated, and accept filters and sorts as
query parameters.

### Serving the service

Serve the operations of one or more domains with a router:

```elixir
defmodule MyAppWeb.SmithyRouter do
  use AshSmithy.Router,
    domains: [MyApp.Helpdesk],
    model: "/model.json"
end
```

Then forward to it, e.g. from your Phoenix router:

```elixir
scope "/api/smithy" do
  pipe_through [:api]

  forward "/", MyAppWeb.SmithyRouter
end
```

The actor, tenant and context are taken from the conn, as set by `Ash.PlugHelpers`.

### Generating the model

```sh
mix ash_smithy.codegen
```

This writes the Smithy IDL for each domain to `priv/smithy/model/`, along with a
`smithy-build.json`. Then use the [Smithy CLI](https://smithy.io/2.0/guides/smithy-cli/index.html)
to validate the model or generate clients:

```sh
cd priv/smithy && smithy build
```

It also runs as part of `mix ash.codegen`, and `mix ash.codegen --check` fails if the model is
out of date. See `mix help ash_smithy.codegen` for options, including writing the JSON AST.

## Running the protocol compliance tests

The compliance tests need the [Smithy CLI](https://smithy.io/2.0/guides/smithy-cli/index.html)
to fetch the protocol test models. Have `smithy` on your path, or set `SMITHY_CLI`, then:

```sh
mix test
```

Without the Smithy CLI, the compliance tests are skipped unless the protocol test models have
already been fetched to `_build/smithy-protocol-tests.json`.
