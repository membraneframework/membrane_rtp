defmodule Membrane.Element.RTP.MixProject do
  use Mix.Project

  @version "0.4.0-alpha"
  @github_url "https://github.com/membraneframework/membrane_rtp"

  def project do
    [
      app: :membrane_rtp_plugin,
      version: @version,
      elixir: "~> 1.9",
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),

      # hex
      description: "Membrane Multimedia Framework plugin for RTP",
      package: package(),

      # docs
      name: "Membrane RTP plugin",
      source_url: @github_url,
      homepage_url: "https://membraneframework.org",
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test
      ],
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: []
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp docs do
    [
      main: "readme",
      extras: ["README.md"],
      source_ref: "v#{@version}"
    ]
  end

  defp package do
    [
      maintainers: ["Membrane Team"],
      licenses: ["Apache 2.0"],
      links: %{
        "GitHub" => @github_url,
        "Membrane Framework Homepage" => "https://membraneframework.org"
      }
    ]
  end

  defp deps do
    [
      {:membrane_core, "~> 0.5.1"},
      {:membrane_rtp_format, "~> 0.2.0-alpha"},
      {:bunch, "~> 1.0"},
      {:heap, "~> 2.0.2"},

      # Dev
      {:ex_doc, "~> 0.21", only: :dev, runtime: false},
      {:dialyxir, "~> 1.0.0", only: :dev, runtime: false},
      {:credo, "~> 1.4", only: :dev, runtime: false},

      # Test
      {:excoveralls, ">= 0.8.0", only: :test},
      {:membrane_rtp_h264_plugin, "~> 0.3.0-alpha", only: :test},
      {:membrane_rtp_mpegaudio_plugin, "~> 0.4.0-alpha", only: :test},
      {:membrane_element_ffmpeg_h264, "~> 0.2.0", only: :test},
      {:membrane_element_pcap, github: "membraneframework/membrane-element-pcap", only: :test}
    ]
  end
end
