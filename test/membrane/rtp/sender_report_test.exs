# defmodule Membrane.RTP.SenderReportTest do
#   use ExUnit.Case

#   alias Membrane.RTCP.Packet
#   alias Membrane.RTP.Session.SenderReport
#   alias Membrane.Time

#   @ssrc_1 790_688_045
#   @ssrcs MapSet.new([@ssrc_1])
#   @h264_clock_rate 90_000
#   @packet_count 1038
#   @octet_count 17646
#   @rtp_timestamp 1000

#   test "rtp timestamp test" do
#     {_ssrcs, report_data} = SenderReport.init_report(@ssrcs, %SenderReport.Data{})

#     test_wallclock_time = Time.vm_time()

#     mock_serializer_stats = %{
#       clock_rate: @h264_clock_rate,
#       sender_octet_count: @octet_count,
#       sender_packet_count: @packet_count,
#       rtp_timestamp: @rtp_timestamp,
#       timestamp: test_wallclock_time
#     }

#     assert {{:report, %Packet{packets: [sender_report | _]}}, _report_data} =
#              SenderReport.handle_stats(mock_serializer_stats, @ssrc_1, report_data)

#     report_wallclock_timestamp = sender_report.sender_info.wallclock_timestamp
#     report_rtp_timestamp = sender_report.sender_info.rtp_timestamp

#     expected_rtp_timestamp =
#       @rtp_timestamp +
#         ((@h264_clock_rate * (report_wallclock_timestamp - test_wallclock_time))
#          |> Time.to_seconds())

#     assert expected_rtp_timestamp == report_rtp_timestamp
#   end
# end
