defmodule Membrane.RTP.Session.ReceiveBinTest do
  use ExUnit.Case

  import Membrane.Testing.Assertions

  alias Membrane.RTP
  alias Membrane.Testing

  @pcap_file "test/fixtures/rtp/session/demo_rtp.pcap"

  @audio_stream %{ssrc: 439_017_412, frames_n: 20}
  @video_stream %{ssrc: 670_572_639, frames_n: 287}

  @fmt_mapping %{96 => {:H264, 90_000}, 127 => {:MPA, 90_000}}

  defmodule Pauser do
    # move to Core.Testing?
    @moduledoc """
    Forwards buffers until reaching a pause point, i.e. after receiving a configured number of them.
    Continues forwarding upon receiving `:continue` message.
    """
    use Membrane.Filter
    def_input_pad :input, demand_unit: :buffers, caps: :any
    def_output_pad :output, caps: :any

    def_options pause_after: [
                  spec: [integer],
                  default: [],
                  description: "List of pause points."
                ]

    @impl true
    def handle_init(opts) do
      {:ok, Map.from_struct(opts) |> Map.merge(%{cnt: 0})}
    end

    @impl true
    def handle_demand(:output, size, :buffers, _ctx, %{pause_after: [pause | _]} = state) do
      {{:ok, demand: {:input, min(size, pause - state.cnt)}}, state}
    end

    @impl true
    def handle_demand(:output, size, :buffers, _ctx, state) do
      {{:ok, demand: {:input, size}}, state}
    end

    @impl true
    def handle_process(:input, buffer, _ctx, state) do
      {{:ok, buffer: {:output, buffer}}, Map.update!(state, :cnt, &(&1 + 1))}
    end

    @impl true
    def handle_other(:continue, _ctx, state) do
      {{:ok, redemand: :output}, Map.update!(state, :pause_after, &tl/1)}
    end
  end

  defmodule DynamicPipeline do
    use Membrane.Pipeline

    @impl true
    def handle_init(options) do
      spec = %ParentSpec{
        children: [
          pcap: %Membrane.Element.Pcap.Source{path: options.pcap_file},
          pauser: %Pauser{pause_after: [15]},
          rtp: %RTP.Session.ReceiveBin{
            fmt_mapping: options.fmt_mapping,
            rtcp_interval: options.rtcp_interval
          },
          rtcp_source: %Testing.Source{output: options.rtcp_input},
          rtcp_sink: Testing.Sink
        ],
        links: [
          link(:pcap) |> to(:pauser) |> to(:rtp) |> via_out(:rtcp_output) |> to(:rtcp_sink),
          link(:rtcp_source) |> via_in(:rtcp_input) |> to(:rtp)
        ]
      }

      {{:ok, spec: spec}, %{}}
    end

    @impl true
    def handle_notification({:new_rtp_stream, ssrc, _pt}, :rtp, state) do
      spec = %ParentSpec{
        children: [
          {ssrc, Testing.Sink}
        ],
        links: [
          link(:rtp) |> via_out(Pad.ref(:output, ssrc)) |> to(ssrc)
        ]
      }

      {{:ok, spec: spec}, state}
    end

    @impl true
    def handle_notification(_notification, _from, state) do
      {:ok, state}
    end
  end

  @tag :focus
  test "RTP streams passes through RTP bin properly" do
    sender_report =
      %Membrane.RTCP.SenderReportPacket{
        reports: [],
        sender_info: %{
          rtp_timestamp: 555_689_664,
          sender_octet_count: 27_843,
          sender_packet_count: 158,
          wallclock_timestamp: 1_582_306_181_225_999_999
        },
        ssrc: 670_572_639
      }
      |> Membrane.RTCP.Packet.to_binary()

    {:ok, pipeline} =
      %Testing.Pipeline.Options{
        module: DynamicPipeline,
        custom_args: %{
          pcap_file: @pcap_file,
          fmt_mapping: @fmt_mapping,
          rtcp_input: [sender_report],
          rtcp_interval: Membrane.Time.second()
        }
      }
      |> Testing.Pipeline.start_link()

    Testing.Pipeline.play(pipeline)
    assert_pipeline_playback_changed(pipeline, _, :playing)

    audio_ssrc = @audio_stream.ssrc
    video_ssrc = @video_stream.ssrc

    assert_start_of_stream(pipeline, ^audio_ssrc)
    assert_start_of_stream(pipeline, ^video_ssrc)

    assert_sink_buffer(pipeline, :rtcp_sink, %Membrane.Buffer{})
    assert_sink_buffer(pipeline, :rtcp_sink, %Membrane.Buffer{})
    Testing.Pipeline.message_child(pipeline, :pauser, :continue)

    1..@video_stream.frames_n
    |> Enum.each(fn _i ->
      assert_sink_buffer(pipeline, video_ssrc, %Membrane.Buffer{})
    end)

    1..@audio_stream.frames_n
    |> Enum.each(fn _i ->
      assert_sink_buffer(pipeline, audio_ssrc, %Membrane.Buffer{})
    end)

    assert_end_of_stream(pipeline, ^audio_ssrc)
    assert_end_of_stream(pipeline, ^video_ssrc)
    Testing.Pipeline.stop(pipeline)
    assert_pipeline_playback_changed(pipeline, _, :stopped)
  end
end
