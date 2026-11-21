defmodule App do
  @moduledoc """
  Everything the targets share, so task, server and lambda cannot drift apart
  in behaviour. Mirrors `src/main.py` in the Python layer.
  """

  require Logger

  @typedoc """
  Where the service gets the things it depends on. Deployed code is online; a
  local run opts out with MODE=local.

  Online is the default so that nothing has to be set on AWS, and forgetting
  to set it locally fails loudly on the first AWS call rather than silently
  running against stub data in production.
  """
  @type mode :: :online | :local

  @spec get_mode() :: mode
  def get_mode do
    case System.get_env("MODE", "online") |> String.downcase() do
      "local" ->
        :local

      "online" ->
        :online

      other ->
        Logger.warning("unknown MODE #{inspect(other)}, falling back to online")
        :online
    end
  end

  @doc """
  The one function a target calls, so the behaviour is the same however this
  is deployed.
  """
  @spec process_request(String.t(), mode | nil) :: String.t()
  def process_request(event_data, mode \\ nil) do
    mode = mode || get_mode()

    # The settings: the block of the config object container_config.env
    # names, with credentials from the secret (App.Config). Read once, then
    # kept. Log what was read, never a credential or key.
    config = App.Config.get!(mode == :local)

    Logger.info(
      "block #{config.block}: #{map_size(config.settings)} settings, " <>
        "#{map_size(config.credentials)} credentials"
    )

    input = %{event_data: event_data}
    Logger.info("input: #{inspect(input)}")

    output = f1(input)

    Logger.info("output: #{output} for input: #{inspect(input)}")
    output
  end

  @doc """
  The one piece of work the template does, so there is something to replace
  with the real thing. Mirrors `lib/package_a/module_x.py`.

  ## Examples
      iex> App.f1(%{event_data: "abc"})
      "#{:crypto.hash(:sha256, inspect(%{event_data: "abc"})) |> Base.encode16(case: :lower)}"
  """
  @spec f1(map) :: String.t()
  def f1(input) do
    :crypto.hash(:sha256, inspect(input)) |> Base.encode16(case: :lower)
  end
end
