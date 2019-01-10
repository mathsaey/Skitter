# Copyright 2018, Mathijs Saey, Vrije Universiteit Brussel

# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.

defmodule Skitter.Runtime.Nodes do
  @moduledoc false

  require Logger

  alias __MODULE__
  alias Skitter.Runtime.Worker

  def supervisor(:master), do: Nodes.Supervisor

  @doc """
  List all nodes.
  """
  def all, do: Nodes.Registry.all()

  @doc """
  Subscribe to node join events.

  When a node joins the network, the pid that called this function will
  receive `{:node_join, node}`.
  """
  defdelegate subscribe_join, to: Nodes.Notifier

  @doc """
  Subscribe to node leave events.

  When a node leaves the network, the pid that called this function will
  receive `{:node_leave, node, reason}`.
  When the node was disconnected through `Nodes.disconnect`, the provided reason
  will be `:removed`.
  """
  defdelegate subscribe_leave, to: Nodes.Notifier

  @doc """
  Unsubscribe from join events.

  The pid will receive no further notifications when a node joins the network.
  """
  defdelegate unsubscribe_join, to: Nodes.Notifier

  @doc """
  Unsubscribe from leave events.

  The pid will receive no further notifications when a node leaves the network.
  """
  defdelegate unsubscribe_leave, to: Nodes.Notifier

  @doc """
  Execute `{mod, func, args}` on `node`, block until a result is available.
  """
  defdelegate on(node, mod, func, args), to: Nodes.Task

  @doc """
  Execute `{mod, func, args}` on every node, obtain the results in a list.
  """
  defdelegate on_all(mod, func, args), to: Nodes.Task

  defdelegate select_permanent(), to: Nodes.LoadBalancer
  defdelegate select_transient(), to: Nodes.LoadBalancer

  def on_permanent(mod, func, args) do
    Nodes.Task.on(select_permanent(), mod, func, args)
  end

  def on_transient(mod, func, args) do
    Nodes.Task.on(select_transient(), mod, func, args)
  end

  # --------------- #
  # Node Connection #
  # --------------- #

  def connect([]), do: true

  def connect(n = :nonode@nohost) do
    # Allow the local node to act as a worker in local mode
    if Worker.verify_worker(n) && !Node.alive?() do
      Nodes.Monitor.start_monitor(n)
      Nodes.Notifier.notify_join(n)
      Worker.register_master(n)
      true
    else
      :invalid
    end
  end

  def connect(nodes) when is_list(nodes) do
    if Node.alive?() do
      lst =
        nodes
        |> Enum.map(&connect/1)
        |> Enum.reject(&(&1 == true))
      lst == [] || lst
    else
      :not_distributed
    end
  end

  def connect(node) when is_atom(node) do
    with true <- Node.connect(node),
         true <- Worker.verify_worker(node),
         :ok <- Worker.register_master(node),
         {:ok, _} <- Nodes.Monitor.start_monitor(node),
         :ok <- Nodes.Notifier.notify_join(node)
    do
      Logger.info("Registered new worker: #{node}")
      true
    else
      :already_connected -> {:already_connected, node}
      :not_connected -> {:not_connected, node}
      :invalid -> {:no_skitter_worker, node}
      false -> {:not_connected, node}
      any -> {:error, any, node}
    end
  end

  def disconnect(node) do
    Worker.remove_master(node)
    Nodes.Monitor.remove_monitor(node)
  end
end
