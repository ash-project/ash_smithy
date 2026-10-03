defmodule AshSmithy.Manifest do
  @moduledoc """
  Builds the `Ash.Info.Manifest` that AshSmithy derives Smithy shapes from.

  Each resource gets a manifest rooted at that resource, with the actions exposed by its
  Smithy operations as entrypoints. Manifests are cached, keyed by the resource module's md5,
  so a recompiled resource gets a fresh manifest.
  """

  alias Ash.Info.Manifest

  defstruct [:resource, :manifest, :resources, :actions, :types]

  @type t :: %__MODULE__{
          resource: Manifest.Resource.t(),
          manifest: Manifest.t(),
          resources: Manifest.resource_lookup(),
          actions: Manifest.action_lookup(),
          types: Manifest.type_lookup()
        }

  @doc "The manifest for a resource. Works for embedded and non Smithy resources too."
  @spec for_resource(Ash.Resource.t()) :: t()
  def for_resource(resource) do
    key = {__MODULE__, resource, resource.module_info(:md5)}

    case :persistent_term.get(key, nil) do
      nil ->
        manifest = build(resource)
        :persistent_term.put(key, manifest)
        manifest

      manifest ->
        manifest
    end
  end

  @doc "The manifest definition of a resource's action."
  @spec action(Ash.Resource.t(), atom) :: Manifest.Action.t()
  def action(resource, action) do
    case Manifest.get_action(for_resource(resource).actions, resource, action) do
      nil ->
        raise ArgumentError,
              "Action #{inspect(action)} of #{inspect(resource)} is not in its manifest. " <>
                "Actions exposed over Smithy must be public."

      action ->
        action
    end
  end

  @doc "Resolves a `:type_ref` type to its definition."
  @spec resolve(t(), Manifest.Type.t()) :: Manifest.Type.t()
  def resolve(%__MODULE__{types: types}, %Manifest.Type{kind: :type_ref, module: module}) do
    Manifest.get_type!(types, module)
  end

  def resolve(_manifest, type), do: type

  defp build(resource) do
    entrypoints =
      if AshSmithy.Resource.Info.smithy_resource?(resource) do
        resource
        |> AshSmithy.Resource.Info.operations()
        |> Enum.map(&{resource, &1.action})
        |> Enum.uniq()
      else
        []
      end

    # With explicit entrypoints the otp app's domains aren't used, the resource is the root
    {:ok, manifest} =
      Manifest.generate(
        otp_app: :ash_smithy,
        action_entrypoints: entrypoints,
        overrides: [always: [resources: [resource]]]
      )

    resources = Manifest.resource_lookup(manifest)
    types = Manifest.type_lookup(manifest)

    # Embedded resources are types, not resources, in the manifest
    definition =
      case Map.fetch(resources, resource) do
        {:ok, definition} -> definition
        :error -> Map.fetch!(types, resource).resource
      end

    %__MODULE__{
      resource: definition,
      manifest: manifest,
      resources: resources,
      actions: Manifest.action_lookup(manifest),
      types: types
    }
  end
end
