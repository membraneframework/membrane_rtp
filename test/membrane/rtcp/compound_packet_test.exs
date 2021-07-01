# defmodule Membrane.RTCP.PacketTest do
#   use ExUnit.Case, async: true

#   alias Membrane.RTCP
#   alias Membrane.RTCP.Fixtures

#   @sample_ssrc 1_374_823_241

#   test "compound packets parsing" do
#     packet = Fixtures.sample_packet_binary()
#     assert {:ok, %RTCP.Packet{packets: packets}} = RTCP.Packet.parse(packet)

#     assert %RTCP.SenderReportPacket{reports: [], sender_info: %{}, ssrc: @sample_ssrc} =
#              hd(packets)

#     assert %RTCP.ByePacket{ssrcs: [@sample_ssrc]} = Enum.at(packets, 1)
#   end

#   test "reconstructed packets are (almost) equal to original packets" do
#     packet = Fixtures.sample_packet_binary()
#     assert {:ok, packets} = RTCP.Packet.parse(packet)
#     regenerated_packet = RTCP.Packet.serialize(packets)

#     <<head::binary-size(12), ref_ntp_lsw::32, tail::binary>> = packet

#     assert <<^head::binary-size(12), ntp_lsw::32, ^tail::binary>> = regenerated_packet

#     # The least significant word of NTP timestamp (fractional part) might differ due to rounding errors
#     assert_in_delta ntp_lsw, ref_ntp_lsw, 10
#   end
# end
