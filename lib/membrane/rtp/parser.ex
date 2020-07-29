defmodule Membrane.RTP.Parser do
  @moduledoc """
  Parses RTP packets.
  See `options/0` for available options
  """

  use Membrane.Filter

  alias Membrane.Buffer
  alias Membrane.Element.Action
  alias Membrane.RTP
  alias Membrane.RTP.{Header, Packet}

  @metadata_fields [:timestamp, :sequence_number, :ssrc, :payload_type]

  def_output_pad :output,
    caps: RTP

  def_input_pad :input,
    caps: :any,
    demand_unit: :buffers

  defmodule State do
    @moduledoc false
    defstruct payload_type: nil

    @type t :: %__MODULE__{
            payload_type: RTP.payload_type_t() | nil
          }
  end

  @impl true
  def handle_init(_options) do
    {:ok, %State{}}
  end

  @impl true
  def handle_process(:input, %Buffer{payload: buffer_payload} = buffer, _ctx, state) do
    with {:ok, %Packet{} = packet} <- Packet.parse(buffer_payload),
         {commands, state} <- build_commands(packet, buffer, state) do
      {{:ok, commands}, state}
    else
      {:error, reason} ->
        {{:error, reason}, state}
    end
  end

  @impl true
  def handle_demand(:output, size, _unit, _ctx, state) do
    {{:ok, demand: {:input, size}}, state}
  end

  @spec build_commands(Packet.t(), Buffer.t(), State.t()) :: {[Action.t()], State.t()}
  defp build_commands(packet, buffer, state)

  defp build_commands(%Packet{} = packet, buffer, %State{payload_type: nil} = state) do
    %Packet{header: %Header{payload_type: pt}} = packet
    {commands, state} = build_commands(packet, buffer, %State{state | payload_type: pt})
    caps = build_caps(packet)
    {[caps | commands], state}
  end

  defp build_commands(packet, buffer, %State{payload_type: _} = state) do
    buffer = build_buffer(buffer, packet)
    commands = [buffer: {:output, buffer}]
    {commands, state}
  end

  @spec build_caps(Packet.t()) :: Action.caps_t()
  defp build_caps(%Packet{header: header}) do
    %Header{
      payload_type: payload_type
    } = header

    caps = %RTP{payload_type: payload_type}

    {:caps, {:output, caps}}
  end

  @spec build_buffer(Buffer.t(), Packet.t()) :: Buffer.t()
  defp build_buffer(
         %Buffer{metadata: metadata} = original_buffer,
         %Packet{payload: payload} = packet
       ) do
    updated_metadata = build_metadata(packet, metadata)
    %Buffer{original_buffer | payload: payload, metadata: updated_metadata}
  end

  @spec build_metadata(Packet.t(), map()) :: map()
  defp build_metadata(%Packet{header: %Header{} = header}, metadata) do
    extracted = Map.take(header, @metadata_fields)
    Map.put(metadata, :rtp, extracted)
  end
end
