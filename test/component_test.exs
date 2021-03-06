# Copyright 2018 - 2021, Mathijs Saey, Vrije Universiteit Brussel

# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.

defmodule Skitter.ComponentTest do
  use ExUnit.Case, async: true

  import Skitter.Component
  alias Skitter.Component.Callback.{Info, Result}

  defmodule ComponentModule do
    @behaviour Skitter.Component
    alias Skitter.Component.Callback.{Info, Result}

    defstruct [:field]

    def _sk_component_info(:strategy), do: Strategy
    def _sk_component_info(:in_ports), do: [:input]
    def _sk_component_info(:out_ports), do: [:output]

    def _sk_callback_list, do: [example: 1]

    def _sk_callback_info(:example, 1) do
      %Info{read: [:field], write: [], publish: [:arg]}
    end

    def example(state, arg) do
      result = Map.get(state, :field)
      %Result{state: state, publish: [arg: arg], result: result}
    end
  end

  doctest Skitter.Component
end
