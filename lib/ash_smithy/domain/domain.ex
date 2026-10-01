defmodule AshSmithy.Domain do
  @smithy %Spark.Dsl.Section{
    name: :smithy,
    describe: "Configure the Smithy service generated for the domain.",
    examples: [
      """
      smithy do
        namespace "com.example.helpdesk"
        service "Helpdesk"
        version "2026-10-01"
      end
      """
    ],
    schema: [
      namespace: [
        type: :string,
        required: true,
        doc: "The Smithy namespace that all shapes are defined in, e.g. `com.example.helpdesk`."
      ],
      service: [
        type: :string,
        doc: "The name of the service shape. Defaults to the last segment of the domain module."
      ],
      version: [
        type: :string,
        doc: "The version of the service."
      ],
      title: [
        type: :string,
        doc: "A human readable title for the service. Adds the `@title` trait."
      ],
      description: [
        type: :string,
        doc: "Documentation for the service. Defaults to the domain's description."
      ],
      protocol: [
        type: {:one_of, [:rest_json1]},
        default: :rest_json1,
        doc: "The protocol used to expose the service."
      ],
      prefix: [
        type: :string,
        default: "",
        doc: "A path prefix applied to all of the service's operations, e.g. `/v1`."
      ]
    ]
  }

  @moduledoc """
  Exposes an Ash domain as a service in a Smithy model.
  """

  use Spark.Dsl.Extension,
    sections: [@smithy],
    verifiers: [AshSmithy.Domain.Verifiers.VerifyOperations]

  @doc false
  # Called by `mix ash.codegen`
  def codegen(argv) do
    Mix.Task.reenable("ash_smithy.codegen")
    Mix.Task.run("ash_smithy.codegen", argv)
  end
end
