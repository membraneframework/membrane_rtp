defmodule Membrane.RTCP.Receiver do
  use Membrane.Filter

  alias Membrane.RTCPEvent
  alias Membrane.RTCP.{FeedbackPacket, SenderReportPacket}
  alias Membrane.{RTCP, RTP}
  alias Membrane.Time

  require Membrane.Logger

  def_input_pad :input, demand_unit: :buffers, caps: :any
  def_output_pad :output, caps: :any

  def_options local_ssrc: [], remote_ssrc: [], report_interval: []

  @impl true
  def handle_init(opts) do
    {:ok, Map.from_struct(opts) |> Map.merge(%{fir_seq_num: 0, sr_info: %{}})}
  end

  @impl true
  def handle_prepared_to_playing(_ctx, state) do
    # FIXME: reenable timer and fix receiver reports
    # {{:ok, start_timer: {:stats_timer, state.report_interval}}, state}

    # FIXME: find out why FIRs on FIR requests are not sufficient
    # TODO: make interval configurable
    {{:ok, start_timer: {:fir_timer, Membrane.Time.second()}}, state}
  end

  @impl true
  def handle_playing_to_prepared(_ctx, state) do
    {{:ok, stop_timer: :fir_timer}, state}
  end

  @impl true
  def handle_tick(:stats_timer, _ctx, state) do
    {{:ok, event: {:output, %RTP.JitterBuffer.StatsRequestEvent{}}}, state}
  end

  @impl true
  def handle_tick(:fir_timer, _ctx, state) do
    send_fir(state)
  end

  @impl true
  def handle_event(:input, %RTCPEvent{rtcp: %SenderReportPacket{} = rtcp} = event, _ctx, state) do
    <<_::16, cut_wallclock_ts::32, _::16>> =
      Time.to_ntp_timestamp(rtcp.sender_info.wallclock_timestamp)

    sr_info = %{cut_wallclock_ts: cut_wallclock_ts, arrival_ts: event.arrival_timestamp}
    {:ok, %{state | sr_info: sr_info}}
  end

  @impl true
  def handle_event(:input, %RTCPEvent{} = event, _ctx, state) do
    Membrane.Logger.warn("Received unknown RTCP packet: #{inspect(event)}")
    {:ok, state}
  end

  @impl true
  def handle_event(:output, %RTP.JitterBuffer.StatsEvent{stats: :no_stats}, _ctx, state) do
    {:ok, state}
  end

  @impl true
  def handle_event(:output, %RTP.JitterBuffer.StatsEvent{stats: stats}, _ctx, state) do
    now = Time.vm_time()
    delay_since_sr = now - Map.get(state.sr_info, :arrival_ts, now)

    report_block = %RTCP.ReportPacketBlock{
      ssrc: state.remote_ssrc,
      fraction_lost: stats.fraction_lost,
      total_lost: stats.total_lost,
      highest_seq_num: stats.highest_seq_num,
      interarrival_jitter: trunc(stats.interarrival_jitter),
      last_sr_timestamp: Map.get(state.sr_info, :cut_wallclock_ts, 0),
      # delay_since_sr is expressed in 1/65536 seconds, see https://tools.ietf.org/html/rfc3550#section-6.4.1
      delay_since_sr: Time.to_seconds(65536 * delay_since_sr)
    }

    packet = %RTCP.ReceiverReportPacket{ssrc: state.local_ssrc, reports: [report_block]}
    {{:ok, event: {:input, %RTCPEvent{rtcp: packet}}}, state}
  end

  @impl true
  def handle_event(:output, %Membrane.KeyframeRequestEvent{}, _ctx, state) do
    send_fir(state)
  end

  @impl true
  def handle_event(pad, event, ctx, state), do: super(pad, event, ctx, state)

  @impl true
  def handle_demand(:output, size, :buffers, _ctx, state) do
    {{:ok, demand: {:input, size}}, state}
  end

  @impl true
  def handle_process(:input, buffer, _ctx, state) do
    {{:ok, buffer: {:output, buffer}}, state}
  end

  defp send_fir(state) do
    rtcp = %FeedbackPacket{
      origin_ssrc: state.local_ssrc,
      payload: %FeedbackPacket.FIR{
        target_ssrc: state.remote_ssrc,
        seq_num: state.fir_seq_num
      }
    }

    event = %RTCPEvent{rtcp: rtcp}
    state = Map.update!(state, :fir_seq_num, &(&1 + 1))
    {{:ok, event: {:input, event}}, state}
  end
end
