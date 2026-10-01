defmodule AshSmithy.Resource do
  @operation_schema [
    action: [
      type: :atom,
      required: true,
      doc: "The action to call when this operation is invoked."
    ],
    name: [
      type: :string,
      doc:
        "The name of the operation shape. Defaults to a name derived from the operation kind and resource, e.g. `GetTicket`."
    ],
    method: [
      type: :string,
      doc: "The HTTP method used for the operation, for HTTP based protocols."
    ],
    path: [
      type: :string,
      doc:
        "The HTTP path of the operation, relative to the resource's `base_path`. Identifier labels are written as `{identifier}`."
    ],
    code: [
      type: :pos_integer,
      doc: "The HTTP status code returned on success. Defaults to 200."
    ],
    description: [
      type: :string,
      doc: "Documentation for the operation. Defaults to the action's description."
    ],
    idempotent?: [
      type: :boolean,
      default: false,
      doc:
        "Whether the operation is idempotent. Ash cannot know this, so you must declare it. Adds the `@idempotent` trait."
    ],
    readonly?: [
      type: :boolean,
      default: false,
      doc:
        "Whether a generic action is read-only. Ash cannot know this, so you must declare it. Adds the `@readonly` trait. Read actions are always read-only."
    ],
    query: [
      type: {:list, :atom},
      doc:
        "Inputs that should be bound to query string parameters. For operations using `GET` all inputs are bound to the query string."
    ],
    headers: [
      type: :keyword_list,
      default: [],
      doc: "Inputs that should be bound to HTTP headers, e.g. `[request_id: \"X-Request-Id\"]`."
    ]
  ]

  @query_schema [
    filter: [
      type: {:or, [:boolean, {:list, :atom}]},
      default: true,
      doc: """
      Whether to accept filters as query parameters, or a list of the fields that can be filtered on.
      `true` allows filtering on all filterable fields of the resource's structure.

      Each field gets an equality filter (`?status=open&status=closed`), range filters for
      comparable types (`?estimateGte=1`), a `Contains` filter for strings and an `IsNil` filter
      for nullable fields. Filters are combined with `and`.
      """
    ],
    sort: [
      type: {:or, [:boolean, {:list, :atom}]},
      default: true,
      doc: """
      Whether to accept a `sort` query parameter, or a list of the fields that can be sorted on.
      `true` allows sorting on all sortable fields of the resource's structure.

      Sorts are given as member names, prefixed with `-` for descending order, e.g. `?sort=-insertedAt&sort=subject`.
      """
    ]
  ]

  @instance_schema Keyword.put(@operation_schema, :read_action,
                     type: :atom,
                     doc:
                       "The read action used to look up the record by its identifiers. Defaults to the primary read action."
                   )

  @create %Spark.Dsl.Entity{
    name: :create,
    args: [:action],
    describe: "Exposes a create action as the resource's `create` lifecycle operation.",
    examples: ["create :create", "create :open, name: \"OpenTicket\""],
    target: AshSmithy.Resource.Operation,
    schema: @operation_schema,
    auto_set_fields: [kind: :create]
  }

  @read %Spark.Dsl.Entity{
    name: :read,
    args: [:action],
    describe:
      "Exposes a read action as the resource's `read` lifecycle operation, which fetches a single record by its identifiers.",
    examples: ["read :read"],
    target: AshSmithy.Resource.Operation,
    schema: @operation_schema,
    auto_set_fields: [kind: :read]
  }

  @update %Spark.Dsl.Entity{
    name: :update,
    args: [:action],
    describe: "Exposes an update action as the resource's `update` lifecycle operation.",
    examples: ["update :update"],
    target: AshSmithy.Resource.Operation,
    schema: @instance_schema,
    auto_set_fields: [kind: :update]
  }

  @delete %Spark.Dsl.Entity{
    name: :delete,
    args: [:action],
    describe: """
    Exposes a destroy action as the resource's `delete` lifecycle operation.

    Smithy requires `delete` lifecycle operations to be idempotent. If you do not set
    `idempotent? true`, the operation is still exposed but bound to the resource as a
    regular instance operation instead of the `delete` lifecycle operation.
    """,
    examples: ["delete :destroy, idempotent?: true"],
    target: AshSmithy.Resource.Operation,
    schema: @instance_schema,
    auto_set_fields: [kind: :delete]
  }

  @list %Spark.Dsl.Entity{
    name: :list,
    args: [:action],
    describe: "Exposes a read action as the resource's `list` lifecycle operation.",
    examples: ["list :read", "list :read, paginated?: false"],
    target: AshSmithy.Resource.Operation,
    schema:
      @operation_schema
      |> Keyword.merge(@query_schema)
      |> Keyword.put(:paginated?,
        type: :boolean,
        default: true,
        doc:
          "Whether to paginate the operation. Requires the action to support pagination. Adds the `@paginated` trait."
      ),
    auto_set_fields: [kind: :list]
  }

  @operation %Spark.Dsl.Entity{
    name: :operation,
    args: [:action],
    describe: """
    Exposes an action as an operation bound to a single record of the resource,
    identified by the resource's identifiers.

    Supports read, update and destroy actions.
    """,
    examples: ["operation :close", "operation :assign, path: \"/{id}/assignee\", method: \"PUT\""],
    target: AshSmithy.Resource.Operation,
    schema: @instance_schema,
    auto_set_fields: [kind: :operation]
  }

  @collection_operation %Spark.Dsl.Entity{
    name: :collection_operation,
    args: [:action],
    describe: """
    Exposes an action as an operation bound to the resource's collection, not to a single record.

    Supports create, read (returning a list) and generic actions.
    """,
    examples: ["collection_operation :search", "collection_operation :import_tickets"],
    target: AshSmithy.Resource.Operation,
    schema: Keyword.merge(@operation_schema, @query_schema),
    auto_set_fields: [kind: :collection_operation]
  }

  @operations %Spark.Dsl.Section{
    name: :operations,
    describe: "The operations exposed for the resource.",
    entities: [@create, @read, @update, @delete, @list, @operation, @collection_operation]
  }

  @smithy %Spark.Dsl.Section{
    name: :smithy,
    describe: "Configure how the resource is exposed in the Smithy model.",
    examples: [
      """
      smithy do
        name "Ticket"

        operations do
          create :open
          read :read
          update :update
          delete :destroy, idempotent?: true
          list :read
          operation :close
        end
      end
      """
    ],
    sections: [@operations],
    schema: [
      name: [
        type: :string,
        doc: "The name of the resource shape. Defaults to the last segment of the module name."
      ],
      plural_name: [
        type: :string,
        doc:
          "The plural form of `name`, used for list operations. Defaults to a naive pluralization of `name`."
      ],
      base_path: [
        type: :string,
        doc:
          "The base HTTP path for the resource's operations. Defaults to the dasherized plural name, e.g. `/tickets`."
      ],
      identifiers: [
        type: {:list, :atom},
        doc: "The fields that identify a record. Defaults to the primary key."
      ],
      identifier_names: [
        type: :keyword_list,
        default: [],
        doc:
          "Overrides for the names of the resource's identifiers in the Smithy model. By default an identifier named `id` is named after the resource, e.g. `ticketId`, and other identifiers use their member name."
      ],
      fields: [
        type: {:list, :atom},
        doc:
          "The fields included in the resource's structure. May include public attributes, calculations and aggregates. Defaults to all public attributes."
      ],
      relationships: [
        type: {:list, :atom},
        default: [],
        doc: """
        Public relationships to expose. They are added as optional members of the resource's structure,
        and operations that return records accept an `include` query parameter to load them, e.g. `?include=comments`.
        """
      ],
      member_names: [
        type: :keyword_list,
        default: [],
        doc:
          "Overrides for member names. By default fields and arguments are converted to lowerCamelCase."
      ],
      description: [
        type: :string,
        doc: "Documentation for the resource. Defaults to the resource's description."
      ]
    ]
  }

  @moduledoc """
  Exposes an Ash resource as a resource in a Smithy model.
  """

  use Spark.Dsl.Extension,
    sections: [@smithy],
    verifiers: [AshSmithy.Resource.Verifiers.VerifyOperations]
end
