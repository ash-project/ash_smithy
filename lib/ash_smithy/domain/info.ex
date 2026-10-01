defmodule AshSmithy.Domain.Info do
  @moduledoc "Introspection helpers for `AshSmithy.Domain`."

  use Spark.InfoGenerator, extension: AshSmithy.Domain, sections: [:smithy]

  @doc "The name of the service shape."
  @spec service(Ash.Domain.t()) :: String.t()
  def service(domain) do
    case smithy_service(domain) do
      {:ok, service} -> service
      :error -> domain |> Module.split() |> List.last()
    end
  end

  @doc "The documentation for the service."
  @spec description(Ash.Domain.t()) :: String.t() | nil
  def description(domain) do
    case smithy_description(domain) do
      {:ok, description} -> description
      :error -> Ash.Domain.Info.description(domain)
    end
  end

  @doc "The resources in the domain that are exposed in the Smithy model."
  @spec resources(Ash.Domain.t()) :: [Ash.Resource.t()]
  def resources(domain) do
    domain
    |> Ash.Domain.Info.resources()
    |> Enum.filter(&AshSmithy.Resource.Info.smithy_resource?/1)
  end
end
