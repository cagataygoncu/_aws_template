defmodule AppTest do
  use ExUnit.Case

  doctest App

  # Mirrors tests/unit/test_template.py in the Python layer: f1 returns a
  # SHA-256 hex digest for any input.
  test "f1 returns a sha256 hex digest" do
    result = App.f1(%{event_data: "abc"})

    assert String.length(result) == 64
    assert result =~ ~r/^[0-9a-f]{64}$/
  end
end
