defmodule AshSmithy.MixProject do
  use Mix.Project

  @version "0.1.0"
  @description "Generate Smithy models from Ash resources and serve them over Smithy protocols."

  def project do
    [
      app: :ash_smithy,
      version: @version,
      description: @description,
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      consolidate_protocols: Mix.env() != :test,
      deps: deps(),
      docs: docs(),
      package: package()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/ash-project/ash_smithy"}
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md"]
    ]
  end

  defp deps do
    [
      {:ash, "~> 3.33"},
      {:spark, "~> 2.7"},
      {:plug, "~> 1.16"},
      {:jason, "~> 1.4"},
      {:igniter, "~> 0.8", optional: true},
      {:ex_doc, "~> 0.40", only: [:dev, :test], runtime: false}
    ]
  end
end
