defmodule AshSmithy.Test.Router do
  @moduledoc false
  use AshSmithy.Router, domains: [AshSmithy.Test.Helpdesk], model: "/model.json"
end
