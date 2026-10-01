defmodule AshSmithy.Resource.Info do
  @moduledoc "Introspection helpers for `AshSmithy.Resource`."

  use Spark.InfoGenerator, extension: AshSmithy.Resource, sections: [:smithy]

  @doc "Whether the resource uses the `AshSmithy.Resource` extension."
  @spec smithy_resource?(Ash.Resource.t()) :: boolean
  def smithy_resource?(resource) do
    AshSmithy.Resource in Spark.extensions(resource)
  end

  @doc "The name of the resource shape."
  @spec name(Ash.Resource.t()) :: String.t()
  def name(resource) do
    case smithy_name(resource) do
      {:ok, name} -> name
      :error -> resource |> Module.split() |> List.last()
    end
  end

  @doc "The plural name of the resource shape."
  @spec plural_name(Ash.Resource.t()) :: String.t()
  def plural_name(resource) do
    case smithy_plural_name(resource) do
      {:ok, name} -> name
      :error -> AshSmithy.Naming.pluralize(name(resource))
    end
  end

  @doc "The base HTTP path of the resource."
  @spec base_path(Ash.Resource.t()) :: String.t()
  def base_path(resource) do
    case smithy_base_path(resource) do
      {:ok, path} -> path
      :error -> "/" <> AshSmithy.Naming.dasherize(plural_name(resource))
    end
  end

  @doc "The fields that identify a record."
  @spec identifiers(Ash.Resource.t()) :: [atom]
  def identifiers(resource) do
    case smithy_identifiers(resource) do
      {:ok, identifiers} -> identifiers
      :error -> Ash.Resource.Info.primary_key(resource)
    end
  end

  @doc "The fields included in the resource's structure."
  @spec fields(Ash.Resource.t()) :: [atom]
  def fields(resource) do
    case smithy_fields(resource) do
      {:ok, fields} ->
        fields

      :error ->
        resource
        |> Ash.Resource.Info.public_attributes()
        |> Enum.map(& &1.name)
    end
  end

  @doc "The member name used for a field or argument."
  @spec member_name(Ash.Resource.t(), atom) :: String.t()
  def member_name(resource, field) do
    case Keyword.fetch(smithy_member_names!(resource), field) do
      {:ok, name} -> to_string(name)
      :error -> AshSmithy.Naming.member_name(field)
    end
  end

  @doc "The name of an identifier in the Smithy model."
  @spec identifier_name(Ash.Resource.t(), atom) :: String.t()
  def identifier_name(resource, field) do
    case Keyword.fetch(smithy_identifier_names!(resource), field) do
      {:ok, name} ->
        to_string(name)

      :error when field == :id ->
        AshSmithy.Naming.member_name(Macro.underscore(name(resource))) <> "Id"

      :error ->
        member_name(resource, field)
    end
  end

  @doc "The relationships exposed by the resource."
  @spec relationships(Ash.Resource.t()) :: [Ash.Resource.Relationships.relationship()]
  def relationships(resource) do
    resource
    |> smithy_relationships!()
    |> Enum.map(&Ash.Resource.Info.relationship(resource, &1))
  end

  @doc "The operations exposed by the resource."
  @spec operations(Ash.Resource.t()) :: [AshSmithy.Resource.Operation.t()]
  def operations(resource) do
    smithy_operations(resource)
  end

  @doc "The documentation for the resource."
  @spec description(Ash.Resource.t()) :: String.t() | nil
  def description(resource) do
    case smithy_description(resource) do
      {:ok, description} -> description
      :error -> Ash.Resource.Info.description(resource)
    end
  end
end
