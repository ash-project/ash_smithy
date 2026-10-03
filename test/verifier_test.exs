defmodule AshSmithy.VerifierTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  test "private actions can't be exposed" do
    # Spark reports verifier errors as compile warnings
    capture_io(:stderr, fn ->
      defmodule PrivateAction do
        use Ash.Resource,
          domain: nil,
          validate_domain_inclusion?: false,
          data_layer: Ash.DataLayer.Ets,
          extensions: [AshSmithy.Resource]

        smithy do
          operations do
            create :secret
          end
        end

        actions do
          create :secret do
            public? false
          end
        end

        attributes do
          uuid_primary_key :id, public?: true
        end
      end
    end)

    assert {:error, %Spark.Error.DslError{message: message}} =
             AshSmithy.Resource.Verifiers.VerifyOperations.verify(
               __MODULE__.PrivateAction.spark_dsl_config()
             )

    assert message =~ "is not public"
  end
end
