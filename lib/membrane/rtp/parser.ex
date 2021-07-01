defmodule Membrane.RTP.Parser do
  @moduledoc """
  Parses RTP packets.

  Outputs each packet payload as a separate `Membrane.Buffer`.
  Attaches the following metadata under `:rtp` key: `:timestamp`, `:sequence_number`,
  `:ssrc`, `:payload_type`, `:marker`, `:extension`. See `Membrane.RTP.Header` for
  their meaning and specifications.
  """

  use Membrane.Filter

  alias Membrane.Buffer
  alias Membrane.{RTCP, RTCPEvent, RTP, RemoteStream}

  require Membrane.Logger

  @metadata_fields [
    :timestamp,
    :sequence_number,
    :ssrc,
    :csrcs,
    :payload_type,
    :marker,
    :extension
  ]

  def_input_pad :input,
    caps: {RemoteStream, type: :packetized, content_format: one_of([nil, RTP])},
    demand_mode: :auto

  # demand_unit: :buffers

  def_output_pad :output, demand_inputs: [:input], caps: RTP

  def_output_pad :rtcp_output, mode: :push, caps: :any, availability: :on_request

  @impl true
  def handle_init(_opts) do
    {:ok, %{}}
  end

  @impl true
  def handle_caps(:input, _caps, _ctx, state) do
    {{:ok, caps: {:output, %RTP{}}}, state}
  end

  @impl true
  def handle_process(:input, buffer, _ctx, state) do
    %Buffer{payload: payload} = buffer
    packet_type = RTP.Packet.identify(payload)

    case packet_type do
      :rtp -> RTP.Packet.parse(payload)
      :rtcp -> RTCP.Packet.parse(payload)
    end
    |> case do
      {:ok, packet} ->
        actions = process_packet(packet, buffer.metadata)
        {{:ok, actions}, state}

      {:error, reason} ->
        Membrane.Logger.warn("""
        Couldn't parse #{packet_type} packet:
        #{inspect(payload, limit: :infinity)}
        Reason: #{inspect(reason)}. Ignoring packet.
        """)

        {:ok, state}
    end
  end

  # @impl true
  # def handle_demand(:output, size, :buffers, _ctx, state) do
  #   {{:ok, demand: {:input, size}}, state}
  # end

  @impl true
  def handle_event(:output, %RTCPEvent{} = event, ctx, state) do
    ctx.pads
    |> Map.keys()
    |> Enum.find(fn
      Pad.ref(:rtcp_output, _id) -> true
      _pad -> false
    end)
    |> case do
      nil ->
        {:ok, state}

      pad ->
        buffer = %Buffer{payload: RTCP.Packet.serialize(event.rtcp)}
        {{:ok, buffer: {pad, buffer}}, state}
    end
  end

  @impl true
  def handle_event(pad, event, ctx, state), do: super(pad, event, ctx, state)

  defp process_packet(%RTP.Packet{} = rtp, metadata) do
    extracted = Map.take(rtp.header, @metadata_fields)
    metadata = Map.put(metadata, :rtp, extracted)
    [buffer: {:output, %Buffer{payload: rtp.payload, metadata: metadata}}]
  end

  defp process_packet(rtcp, metadata) do
    Enum.flat_map(rtcp, &process_rtcp(&1, metadata))
    # ++ [redemand: :output]
  end

  defp process_rtcp(%RTCP.FeedbackPacket{payload: %RTCP.FeedbackPacket.PLI{}}, _metadata) do
    Membrane.Logger.warn("Received packet loss indicator RTCP packet")
    []
  end

  defp process_rtcp(%RTCP.SenderReportPacket{ssrc: ssrc} = packet, metadata) do
    event = %RTCPEvent{
      rtcp: %{packet | reports: []},
      ssrcs: [ssrc],
      arrival_timestamp: Map.get(metadata, :arrival_ts, Membrane.Time.vm_time())
    }

    [event: {:output, event}]
  end

  defp process_rtcp(_unknown_rtcp_packet, _metadata) do
    []
  end
end
