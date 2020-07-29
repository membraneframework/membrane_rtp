defmodule Membrane.RTCP.ReceiverReporter do
  @moduledoc """
  Periodically generates RTCP receive reports basing on jitter buffer stats and RTCP sender reports
  and sends them via output.
  """

  use Membrane.Source

  alias Membrane.{Buffer, RTCP, RTP, Time}

  require Logger

  def_output_pad :output, mode: :push, caps: RTCP

  def_options interval: [
                type: :time,
                default: 5 |> Time.seconds(),
                description: """
                Time interval between requesting stats for reports.
                Reports are sent when stats are collected.
                """
              ]

  @impl true
  def handle_init(options) do
    state =
      Map.from_struct(options)
      |> Map.merge(%{pending_ssrcs: MapSet.new(), stats: [], remote_reports: %{}})

    {:ok, state}
  end

  @impl true
  def handle_prepared_to_playing(_ctx, state) do
    {{:ok, caps: {:output, %RTCP{}}, start_timer: {:timer, state.interval}}, state}
  end

  @impl true
  def handle_playing_to_prepared(_ctx, state) do
    {{:ok, stop_timer: :timer}, state}
  end

  @impl true
  def handle_tick(:timer, _ctx, state) do
    actions =
      if Enum.empty?(state.pending_ssrcs) do
        []
      else
        Logger.warn("Not received stats from ssrcs: #{Enum.join(state.pending_ssrcs, ", ")}")
        [buffer: {:output, %Buffer{payload: make_report(state)}}]
      end

    actions = actions ++ [notify: :send_stats]
    state = %{state | pending_ssrcs: MapSet.new(), stats: []}
    {{:ok, actions}, state}
  end

  @impl true
  def handle_other({:ssrcs_to_report, %MapSet{} = ssrcs}, _ctx, state) do
    remote_reports =
      state.remote_reports |> Bunch.KVEnum.filter_by_keys(&MapSet.member?(ssrcs, &1)) |> Map.new()

    {:ok, %{state | pending_ssrcs: ssrcs, remote_reports: remote_reports}}
  end

  @impl true
  def handle_other({:jitter_buffer_stats, stats}, _ctx, state) do
    {local_ssrc, remote_ssrc, %RTP.JitterBuffer.Stats{} = stats} = stats

    state = %{
      state
      | pending_ssrcs: MapSet.delete(state.pending_ssrcs, remote_ssrc),
        stats: [{local_ssrc, remote_ssrc, stats} | state.stats]
    }

    if Enum.empty?(state.pending_ssrcs) do
      buffer = %Buffer{payload: make_report(state)}
      {{:ok, buffer: {:output, buffer}}, %{state | stats: []}}
    else
      {:ok, state}
    end
  end

  @impl true
  def handle_other({:remote_report, rtcp, timestamp}, _ctx, state) do
    state = handle_remote_report(rtcp, timestamp, state)
    {:ok, state}
  end

  defp make_report(state) do
    %RTCP.CompoundPacket{
      packets: Enum.flat_map(state.stats, &generate_receiver_report(&1, state.remote_reports))
    }
    |> RTCP.CompoundPacket.to_binary()
  end

  defp generate_receiver_report({_local_ssrc, _remote_ssrc, :no_stats}, _remote_reports) do
    []
  end

  defp generate_receiver_report(stats_entry, remote_reports) do
    {local_ssrc, remote_ssrc, %RTP.JitterBuffer.Stats{} = stats} = stats_entry
    now = Time.vm_time()
    remote_report = Map.get(remote_reports, remote_ssrc, %{})
    delay_since_sr = now - Map.get(remote_report, :arrival_time, now)

    report_block = %RTCP.ReportPacketBlock{
      ssrc: remote_ssrc,
      fraction_lost: stats.fraction_lost,
      total_lost: stats.total_lost,
      highest_seq_num: stats.highest_seq_num,
      interarrival_jitter: trunc(stats.interarrival_jitter),
      last_sr_timestamp: Map.get(remote_report, :cut_wallclock_timestamp, 0),
      # delay_since_sr is expressed in 1/65536 seconds, see https://tools.ietf.org/html/rfc3550#section-6.4.1
      delay_since_sr: Time.to_seconds(65_536 * delay_since_sr)
    }

    [%RTCP.ReceiverReportPacket{ssrc: local_ssrc, reports: [report_block]}]
  end

  defp handle_remote_report(%RTCP.CompoundPacket{packets: packets}, timestamp, state) do
    Enum.reduce(packets, state, &handle_remote_report(&1, timestamp, &2))
  end

  defp handle_remote_report(%RTCP.SenderReportPacket{} = packet, timestamp, state) do
    %RTCP.SenderReportPacket{sender_info: %{wallclock_timestamp: wallclock_timestamp}, ssrc: ssrc} =
      packet

    <<_::16, cut_wallclock_timestamp::32, _::16>> = Time.to_ntp_timestamp(wallclock_timestamp)

    put_in(state, [:remote_reports, ssrc], %{
      cut_wallclock_timestamp: cut_wallclock_timestamp,
      arrival_time: timestamp
    })
  end

  defp handle_remote_report(_packet, _timestamp, state) do
    state
  end
end
