defmodule AshSmithy.Resource.Operation do
  @moduledoc "Represents an operation exposed by a resource in the Smithy model."

  defstruct [
    :kind,
    :action,
    :name,
    :method,
    :path,
    :code,
    :read_action,
    :description,
    idempotent?: false,
    readonly?: false,
    paginated?: false,
    query: nil,
    filter: true,
    sort: true,
    headers: [],
    __spark_metadata__: nil
  ]

  @type kind ::
          :create | :read | :update | :delete | :list | :operation | :collection_operation

  @type t :: %__MODULE__{
          kind: kind,
          action: atom,
          name: String.t() | nil,
          method: String.t() | nil,
          path: String.t() | nil,
          code: pos_integer | nil,
          read_action: atom | nil,
          description: String.t() | nil,
          idempotent?: boolean,
          readonly?: boolean,
          paginated?: boolean,
          query: [atom] | nil,
          filter: boolean | [atom],
          sort: boolean | [atom],
          headers: Keyword.t(String.t())
        }
end
