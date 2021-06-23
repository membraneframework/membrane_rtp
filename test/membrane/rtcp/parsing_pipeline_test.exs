defmodule Membrane.RTCP.ParsingPipelineTest do
  use ExUnit.Case

  import Membrane.Testing.Assertions

  alias Membrane.RTCP
  alias Membrane.RTCP.{Fixtures, Parser}
  alias Membrane.Testing.{Source, Pipeline}

  test "Pipeline with RTCP parser" do
    packets = Fixtures.packet_list()

    assert {:ok, pipeline} =
             Pipeline.start_link(%Pipeline.Options{
               elements: [
                 source: %Source{output: packets},
                 parser: Parser
               ]
             })

    Pipeline.play(pipeline)

    assert_pipeline_playback_changed(pipeline, :prepared, :playing)
    assert_start_of_stream(pipeline, :parser)

    Fixtures.packet_list_contents()
    |> Enum.each(fn contents ->
      assert_pipeline_notified(pipeline, :parser, {:received_rtcp, report, _timestamp})
      assert %RTCP.Packet{packets: packets} = report
      assert [%RTCP.SenderReportPacket{} = sr, %RTCP.SdesPacket{} = sdes] = packets

      assert sr.ssrc == contents.ssrc
      assert sr.reports == []
      info = sr.sender_info
      assert info.sender_packet_count == contents.sender_packets
      assert info.sender_octet_count == contents.sender_octets
      assert info.rtp_timestamp == contents.rtp_timestamp
      assert info.wallclock_timestamp == contents.wallclock_ts

      assert sdes.chunks[contents.ssrc] == %RTCP.SdesPacket.Chunk{
               cname: contents.cname,
               tool: contents.tool
             }
    end)
  end
end
