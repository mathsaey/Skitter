# Copyright 2018 - 2020, Mathijs Saey, Vrije Universiteit Brussel

# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.

defmodule Skitter.Master.Application do
  @moduledoc false
  require Logger

  use Application
  use Skitter.Application

  alias Skitter.Master.{Config, WorkerConnection}

  def start(:normal, []) do
    noninteractive_skitter_app()

    children = [
      Skitter.Master.ManagerSupervisor,
      Skitter.Master.WorkerConnection.Supervisor
    ]

    {:ok, sup} = Supervisor.start_link(children, strategy: :rest_for_one)
    connect_to_workers()
    {:ok, sup}
  end

  defp connect_to_workers() do
    case WorkerConnection.connect(Config.get(:workers, [])) do
      {:error, reasons} ->
        Logger.error("Could not connect with some workers: #{inspect(reasons)}")
        System.stop(1)

      :ok ->
        :ok
    end
  end
end
