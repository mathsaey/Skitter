# Copyright 2018, Mathijs Saey, Vrije Universiteit Brussel

# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.

defmodule Skitter.MixProject do
  use Mix.Project

  def project do
    [
      app: :skitter,
      name: "Skitter",
      version: "0.2.0-dev",
      source_url: "https://github.com/mathsaey/skitter/",
      homepage_url: "https://soft.vub.ac.be/~mathsaey/skitter/",
      elixir: "~> 1.9",
      deps: deps(),
      docs: docs(),
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      dialyzer: dialyzer()
    ]
  end

  def application do
    [
      mod: {Skitter.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      # Dev tools
      {:credo, "~> 1.0.0", only: :dev, runtime: false},
      {:ex_doc, "~> 0.20.0", only: :dev, runtime: false},
      {:dialyxir, "~> 1.0.0-rc.6", only: :dev, runtime: false}
    ]
  end

  defp docs do
    [
      source_ref: "develop",
      logo: "assets/logo-light_docs.png",
      groups_for_modules: [
        Components: [~r/Skitter\.Component.*/],
        Workflows: [~r/Skitter\.Workflow.*/],
        Runtime: [~r/Skitter\.Runtime.*/]
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/utils"]
  defp elixirc_paths(_), do: ["lib"]

  defp dialyzer, do: [plt_add_apps: [:mix, :iex]]
end
