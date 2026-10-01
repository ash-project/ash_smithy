defmodule AshSmithyTest do
  use ExUnit.Case
  doctest AshSmithy

  test "greets the world" do
    assert AshSmithy.hello() == :world
  end
end
