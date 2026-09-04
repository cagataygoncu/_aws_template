defmodule App.Application do
  @moduledoc """
  The task target: process one request, forever. Mirrors `src/main_task.py`,
  which loops rather than exiting - a container that exits is a stopped ECS
  task, and enough stopped tasks trip the deployment circuit breaker and roll
  the whole deploy back.

  The `server` target needs an HTTP listener on ContainerPort; add a web
  framework (Bandit and Plug, or Phoenix) to `mix.exs` and start it in the
  supervision tree below, calling `App.process_request/1` from the handler.
  """

  use Application

  require Logger

  @interval_ms 3_000

  @impl true
  def start(_type, _args) do
    Logger.info("starting in #{App.get_mode()} mode")

    children = [{Task, &loop/0}]
    Supervisor.start_link(children, strategy: :one_for_one, name: App.Supervisor)
  end

  defp loop do
    # Failures are caught per iteration on purpose: one bad request must not
    # end the process.
    try do
      App.process_request("test")
    rescue
      error -> Logger.error(Exception.format(:error, error, __STACKTRACE__))
    end

    Process.sleep(@interval_ms)
    loop()
  end
end
