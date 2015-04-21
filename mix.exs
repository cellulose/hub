defmodule Hub.Mixfile do

  use Mix.Project

  def project, do: [
    app: :hub,
    version: version,
    elixir: "~> 1.0",
    source_url: "https://github.com/cellulose/hub",
    homepage_url: "http://cellulose.io",
    deps: deps
  ]

  def application, do: [
    mod: { Hub, []}
  ]

  defp deps, do: [
    {:earmark, "~> 0.1", only: :dev},
    {:ex_doc, "~> 0.7", only: :dev}
  ]

  defp version do
    case File.read("VERSION") do
      {:ok, ver} -> String.strip ver
      _ -> "0.0.0-dev"
    end
  end
 end
