defmodule Docker.Mixfile do
  use Mix.Project

  def project do
    [app: :docker,
     version: "0.0.1",
     elixir: "~> 1.0",
     description: desc,
     package: package,
     deps: deps]
  end

  def application do
    [applications: [
        :logger,
        :exjsx,
        :httpoison,
    ]]
  end

  defp deps do
    [
      {:exjsx, "~> 3.0"},
      {:httpoison, "~> 0.5.0"},
    ]
  end

  defp desc do
    """
    Docker API Binding
    """
  end

  defp package do
    [
      licenses: ["MIT"],
      contributors: ["Bearice Ren"],
      links: %{"Github" => "https://github.com/bearice/elixir-docker"}
    ]
  end

end
