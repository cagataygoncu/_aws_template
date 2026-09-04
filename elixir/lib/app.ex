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

    if mode == :online do
      # Where the AWS lookups belong: anything that must not sit in the
      # environment file - endpoints, credentials, keys - comes from Secrets
      # Manager, read with the task role. The Python and Go layers do this
      # through gig_utils; this one has no AWS client as a dependency yet, so
      # add one here when the service needs it. Log that a secret was read,
      # never what it contained.
      Logger.info("online - add the Secrets Manager read here")
    end

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
