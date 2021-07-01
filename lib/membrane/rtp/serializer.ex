defmodule Membrane.RTP.Serializer do
  @moduledoc """
  Serializes RTP payload to RTP packets by adding the RTP header to each of them.

  Accepts the following metadata under `:rtp` key: `:marker`, `:csrcs`, `:extension`.
  See `Membrane.RTP.Header` for their meaning and specifications.
  """
  use Membrane.Filter

  alias Membrane.{Buffer, RTP, RemoteStream, Payload, Time}

  @max_seq_num 65535
  @max_timestamp 0xFFFFFFFF

  # def_input_pad :input, caps: RTP, demand_unit: :buffers
  def_input_pad :input, caps: RTP, demand_mode: :auto
  # def_output_pad :output, caps: {RemoteStream, type: :packetized, content_format: RTP}
  def_output_pad :output,
    caps: {RemoteStream, type: :packetized, content_format: RTP},
    demand_inputs: [:input]

  def_options ssrc: [spec: RTP.ssrc_t()],
              payload_type: [spec: RTP.payload_type_t()],
              clock_rate: [spec: RTP.clock_rate_t()],
              alignment: [
                default: 1,
                spec: pos_integer(),
                description: """
                Number of bytes that each packet should be aligned to.
                Alignment is achieved by adding RTP padding.
                """
              ]

  defmodule State do
    @moduledoc false
    use Bunch.Access

    defstruct sequence_number: 0,
              init_timestamp: 0,
              any_buffer_sent?: false,
              stats_acc: %{
                clock_rate: 0,
                timestamp: 0,
                rtp_timestamp: 0,
                sender_packet_count: 0,
                sender_octet_count: 0
              }

    @type t :: %__MODULE__{
            sequence_number: non_neg_integer(),
            init_timestamp: non_neg_integer(),
            any_buffer_sent?: boolean(),
            stats_acc: %{}
          }
  end

  @impl true
  def handle_init(options) do
    state = %State{
      sequence_number: Enum.random(0..@max_seq_num),
      init_timestamp: Enum.random(0..@max_timestamp)
    }

    state = state |> put_in([:stats_acc, :clock_rate], options.clock_rate)
    {:ok, Map.merge(Map.from_struct(options), state)}
  end

  @impl true
  def handle_caps(:input, _caps, _ctx, state) do
    caps = %RemoteStream{type: :packetized, content_format: RTP}
    {{:ok, caps: {:output, caps}}, state}
  end

  # @impl true
  # def handle_demand(:output, size, :buffers, _ctx, state) do
  #   {{:ok, demand: {:input, size}}, state}
  # end

  @impl true
  def handle_process(:input, %Buffer{payload: payload, metadata: metadata} = buffer, _ctx, state) do
    state = update_counters(buffer, state)

    {rtp_metadata, metadata} = Map.pop(metadata, :rtp, %{})
    %{timestamp: timestamp} = metadata
    rtp_offset = timestamp |> Ratio.mult(state.clock_rate) |> Membrane.Time.to_seconds()
    rtp_timestamp = rem(state.init_timestamp + rtp_offset, @max_timestamp + 1)

    header = %RTP.Header{
      ssrc: state.ssrc,
      marker: Map.get(rtp_metadata, :marker, false),
      payload_type: state.payload_type,
      timestamp: rtp_timestamp,
      sequence_number: state.sequence_number,
      csrcs: Map.get(rtp_metadata, :csrcs, []),
      extension: Map.get(rtp_metadata, :extension)
    }

    packet = %RTP.Packet{header: header, payload: payload}
    payload = RTP.Packet.serialize(packet, align_to: state.alignment)
    buffer = %Buffer{payload: payload, metadata: metadata}
    state = Map.update!(state, :sequence_number, &rem(&1 + 1, @max_seq_num + 1))

    state = %{
      state
      | any_buffer_sent?: true,
        stats_acc: %{state.stats_acc | timestamp: Time.vm_time(), rtp_timestamp: rtp_timestamp}
    }

    {{:ok, buffer: {:output, buffer}}, state}
  end

  @impl true
  def handle_other(:send_stats, _ctx, state) do
    stats = get_stats(state)
    state = %{state | any_buffer_sent?: false}
    {{:ok, notify: {:serializer_stats, stats}}, state}
  end

  @spec get_stats(State.t()) :: %{} | :no_stats
  defp get_stats(%State{any_buffer_sent?: false}), do: :no_stats

  defp get_stats(%State{stats_acc: stats}), do: stats

  defp update_counters(%Buffer{payload: payload}, state) do
    state
    |> update_in(
      [:stats_acc, :sender_octet_count],
      &(&1 + Payload.size(payload))
    )
    |> update_in([:stats_acc, :sender_packet_count], &(&1 + 1))
  end
end
