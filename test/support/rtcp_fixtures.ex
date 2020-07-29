defmodule Membrane.RTCP.Fixtures do
  @moduledoc false

  @external_resource "test/fixtures/rtcp/single_packet.hex"
  @sample_rtcp_packet File.read!(@external_resource)

  @external_resource "test/fixtures/rtcp/packets.hex"
  @sample_rtcp_communication File.read!("test/fixtures/rtcp/packets.hex")

  @spec sample_packet() :: binary()
  def sample_packet, do: hex_to_bin(@sample_rtcp_packet)

  def packet_list() do
    @sample_rtcp_communication
    |> String.split()
    |> Enum.map(&hex_to_bin/1)
  end

  def packet_list_contents() do
    ssrc = 0x62DBEFD0
    cname = "user2465330910@host-447eb16f"
    tool = "GStreamer"

    # Decoded with Wireshark
    [
      %{
        ssrc: ssrc,
        rtp_timestamp: 309_557_624,
        wallclock_ts: to_membrane_time("2020-04-24T11:18:23.349522Z", 999),
        sender_packets: 66,
        sender_octets: 11_215,
        cname: cname,
        tool: tool
      },
      %{
        ssrc: ssrc,
        rtp_timestamp: 309_797_521,
        wallclock_ts: to_membrane_time("2020-04-24T11:18:28.789375Z", 999),
        sender_packets: 300,
        sender_octets: 54_729,
        cname: cname,
        tool: tool
      },
      %{
        ssrc: ssrc,
        rtp_timestamp: 310_053_061,
        wallclock_ts: to_membrane_time("2020-04-24T11:18:34.583922Z", 999),
        sender_packets: 550,
        sender_octets: 101_879,
        cname: cname,
        tool: tool
      },
      %{
        ssrc: ssrc,
        rtp_timestamp: 310_219_178,
        wallclock_ts: to_membrane_time("2020-04-24T11:18:38.350761Z", 999),
        sender_packets: 712,
        sender_octets: 132_620,
        cname: cname,
        tool: tool
      },
      %{
        ssrc: ssrc,
        rtp_timestamp: 310_379_064,
        wallclock_ts: to_membrane_time("2020-04-24T11:18:41.976296Z", 999),
        sender_packets: 868,
        sender_octets: 162_252,
        cname: cname,
        tool: tool
      },
      %{
        ssrc: ssrc,
        rtp_timestamp: 310_497_973,
        wallclock_ts: to_membrane_time("2020-04-24T11:18:44.672643Z", 999),
        sender_packets: 984,
        sender_octets: 184_346,
        cname: cname,
        tool: tool
      }
    ]
  end

  # iso8601 does not allow nanoseconds
  def to_membrane_time(iso8601, nanoseconds) do
    Membrane.Time.from_iso8601!(iso8601) + Membrane.Time.nanoseconds(nanoseconds)
  end

  defp hex_to_bin(hex) do
    hex
    |> String.trim_trailing()
    |> String.upcase()
    |> Base.decode16()
    |> case do
      {:ok, packet} -> packet
    end
  end
end
