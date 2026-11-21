defmodule App.ConfigTest do
  # The config object as shipped: a broken services/*.json fails the build.
  # Mirrors tests/unit/test_config.py in the Python layer. mix test runs from
  # the project root, where container_config.env and services/ are.
  use ExUnit.Case

  alias App.Config

  test "the shipped config object resolves" do
    # both read from container_config.env
    System.delete_env("CONFIG_KEY")
    System.delete_env("CONFIG_BLOCK")
    assert {:ok, config} = Config.load(true)
    assert map_size(config.settings) > 0
  end

  test "a block's keys win over its profile's" do
    data = %{
      "profiles" => %{"p" => %{"A" => 1, "B" => 1}},
      "blk" => %{"PROFILE" => "p", "B" => 2}
    }

    assert Config.resolve_block(data, "blk") == {:ok, %{"A" => 1, "B" => 2, "PROFILE" => "p"}}
  end

  test "a missing block or profile fails" do
    assert {:error, "the config object has no block" <> _} = Config.resolve_block(%{}, "blk")
    assert {:error, message} = Config.resolve_block(%{"blk" => %{"PROFILE" => "nope"}}, "blk")
    assert message =~ "names profile"
  end

  test "an unknown credential id fails" do
    assert {:error, message} =
             Config.check_credentials(%{"X_CREDENTIAL" => "cred_9"}, %{"cred_1" => %{}})

    assert message =~ "X_CREDENTIAL=cred_9"
  end
end
