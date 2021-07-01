defmodule Membrane.RTP.VAD do
  @moduledoc """
  Simple vad based on audio level sent in RTP header.

  To make this module work appropriate RTP header extension has to be set in SDP offer/answer.

  If avg of audio level in packets in `time_window` exceeds `vad_threshold` it emits
  notification `t:speech_notification_t/0`.

  When avg falls below `vad_threshold` and doesn't exceed it in the next `vad_silence_timer`
  it emits notification `t:silence_notification_t/0`.
  """
  use Membrane.Filter

  def_input_pad :input,
    availability: :always,
    caps: :any,
    demand_mode: :auto

  # demand_unit: :buffers,

  def_output_pad :output,
    availability: :always,
    caps: :any,
    demand_inputs: [:input]

  def_options time_window: [
                spec: pos_integer(),
                default: 2_000_000_000,
                description: "Time window (in `ns`) in which avg audio level is measured."
              ],
              min_packet_num: [
                spec: pos_integer(),
                default: 50,
                description: """
                Minimal number of packets to count avg audio level from.
                Speech won't be detected until there are enough packets.
                """
              ],
              vad_threshold: [
                spec: -127..0,
                default: -50,
                description: """
                Audio level in dBov representing vad threshold.
                Values above are considered to represent voice activity.
                Value -127 represents digital silence.
                """
              ],
              vad_silence_time: [
                spec: pos_integer(),
                default: 300,
                description: """
                Time to wait before emitting notification `t:silence_notification_t/0` after audio track is
                no longer considered to represent speech.
                If at this time audio track is considered to represent speech again the notification will not be sent.
                """
              ]

  @typedoc """
  Notification sent after detecting speech activity.
  """
  @type speech_notification_t() :: {:vad, :speech}

  @typedoc """
  Notification sent after detecting silence activity.
  """
  @type silence_notification_t() :: {:vad, :silence}

  @impl true
  def handle_init(opts) do
    state = %{
      audio_levels: Qex.new(),
      vad: :silence,
      vad_silence_timestamp: 0,
      current_timestamp: 0,
      time_window: opts.time_window,
      min_packet_num: opts.min_packet_num,
      vad_threshold: opts.vad_threshold,
      vad_silence_time: opts.vad_silence_time,
      audio_levels_sum: 0,
      audio_levels_count: 0
    }

    {:ok, state}
  end

  # @impl true
  # def handle_demand(:output, size, :buffers, _ctx, state) do
  #   {{:ok, demand: {:input, size}}, state}
  # end

  @impl true
  def handle_process(:input, %Membrane.Buffer{} = buffer, _ctx, state) do
    <<_id::4, _len::4, _v::1, level::7, _rest::binary-size(2)>> =
      buffer.metadata.rtp.extension.data

    state = %{state | current_timestamp: buffer.metadata.timestamp}
    state = filter_old_audio_levels(state)
    state = add_new_audio_level(state, level)
    audio_levels_vad = get_audio_levels_vad(state)
    actions = [buffer: {:output, buffer}] ++ maybe_notify(audio_levels_vad, state)
    state = update_vad_state(audio_levels_vad, state)
    {{:ok, actions}, state}
  end

  defp filter_old_audio_levels(state) do
    Enum.reduce_while(state.audio_levels, state, fn {level, timestamp}, state ->
      if state.current_timestamp - timestamp > state.time_window do
        {_level, audio_levels} = Qex.pop(state.audio_levels)

        state = %{
          state
          | audio_levels_sum: state.audio_levels_sum - level,
            audio_levels_count: state.audio_levels_count - 1,
            audio_levels: audio_levels
        }

        {:cont, state}
      else
        {:halt, state}
      end
    end)
  end

  defp add_new_audio_level(state, level) do
    audio_levels = Qex.push(state.audio_levels, {-level, state.current_timestamp})
    state = %{state | audio_levels: audio_levels}
    state = %{state | audio_levels_sum: state.audio_levels_sum + -level}
    %{state | audio_levels_count: state.audio_levels_count + 1}
  end

  defp get_audio_levels_vad(state) do
    if state.audio_levels_count >= state.min_packet_num and avg(state) >= state.vad_threshold,
      do: :speech,
      else: :silence
  end

  defp avg(state), do: state.audio_levels_sum / state.audio_levels_count

  defp maybe_notify(audio_levels_vad, state) do
    if vad_silence?(audio_levels_vad, state) or vad_speech?(audio_levels_vad, state) do
      [notify: {:vad, audio_levels_vad}]
    else
      []
    end
  end

  defp update_vad_state(audio_levels_vad, state) do
    cond do
      vad_maybe_silence?(audio_levels_vad, state) ->
        Map.merge(state, %{vad: :maybe_silence, vad_silence_timestamp: state.current_timestamp})

      vad_silence?(audio_levels_vad, state) or vad_speech?(audio_levels_vad, state) ->
        Map.merge(state, %{vad: audio_levels_vad})

      true ->
        state
    end
  end

  defp vad_silence?(audio_levels_vad, state),
    do: state.vad == :maybe_silence and audio_levels_vad == :silence and timer_expired?(state)

  defp vad_speech?(audio_levels_vad, state) do
    (state.vad == :maybe_silence and audio_levels_vad == :speech) or
      (state.vad == :silence and audio_levels_vad == :speech)
  end

  defp vad_maybe_silence?(audio_levels_vad, state),
    do: state.vad == :speech and audio_levels_vad == :silence

  defp timer_expired?(state),
    do: state.current_timestamp - state.vad_silence_timestamp > state.vad_silence_time
end
