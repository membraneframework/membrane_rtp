defmodule Membrane.RTP.SSRCRouter do
  @moduledoc """
  A filter separating RTP packets from different SSRCs into different outpts.

  When receiving a new SSRC, it creates a new pad and notifies its parent (`t:new_ssrc_notification/0`) that should link
  the new output pad.
  """

  use Membrane.Filter

  alias Membrane.RTP

  def_input_pad :input, demand_unit: :buffers, caps: RTP, availability: :on_request

  def_output_pad :output, caps: :any, availability: :on_request

  defmodule State do
    @moduledoc false

    alias Membrane.RTP

    @type t() :: %__MODULE__{
            pads: %{RTP.ssrc_t() => [input_pad :: Pad.ref_t()]},
            linking_buffers: %{RTP.ssrc_t() => [Membrane.Buffer.t()]}
          }

    defstruct pads: %{},
              linking_buffers: %{}
  end

  @typedoc """
  Notification sent when an RTP packet with new SSRC arrives and new output pad should be linked
  """
  @type new_ssrc_notification() ::
          {:new_ssrc_stream, RTP.ssrc_t(), RTP.payload_type_t()}

  @impl true
  def handle_init(_options), do: {:ok, %State{}}

  @impl true
  def handle_pad_added(Pad.ref(:output, ssrc) = pad, _ctx, state) do
    %State{linking_buffers: lb} = state

    {buffers_to_send, new_lb} = lb |> Map.pop(ssrc)
    new_state = %State{state | linking_buffers: new_lb}

    {{:ok, buffer: {pad, Enum.reverse(buffers_to_send)}}, new_state}
  end

  @impl true
  def handle_pad_added(Pad.ref(:input, _id), _ctx, state) do
    {:ok, state}
  end

  @impl true
  def handle_pad_removed(Pad.ref(:input, _) = pad, _ctx, state) do
    new_pads =
      state.pads
      |> Enum.filter(fn {_ssrc, p} -> p != pad end)
      |> Enum.into(%{})

    {:ok, %State{state | pads: new_pads}}
  end

  @impl true
  def handle_prepared_to_playing(ctx, state) do
    actions =
      ctx.pads
      |> Enum.map(fn {pad_ref, _pad_data} -> {:demand, {pad_ref, 1}} end)

    {{:ok, actions}, state}
  end

  @impl true
  def handle_demand(Pad.ref(:output, ssrc), _size, _unit, ctx, state) do
    input_pad = state.pads[ssrc]

    {{:ok, demand: {input_pad, &(&1 + ctx.incoming_demand)}}, state}
  end

  @impl true
  def handle_process(Pad.ref(:input, _id) = pad, buffer, _ctx, state) do
    ssrc = buffer.metadata.rtp.ssrc

    cond do
      new_stream?(ssrc, state.pads) ->
        pt = buffer.metadata.rtp.payload_type

        new_pads = state.pads |> Map.put(ssrc, pad)

        {{:ok, notify: {:new_rtp_stream, ssrc, pt}, demand: {pad, &(&1 + 1)}},
         %{
           state
           | pads: new_pads,
             linking_buffers: Map.put(state.linking_buffers, ssrc, [buffer])
         }}

      waiting_for_linking?(ssrc, state) ->
        new_state = %{
          state
          | linking_buffers: Map.update!(state.linking_buffers, ssrc, &[buffer | &1])
        }

        {{:ok, demand: {pad, &(&1 + 1)}}, new_state}

      true ->
        {{:ok, buffer: {Pad.ref(:output, ssrc), buffer}}, state}
    end
  end

  defp waiting_for_linking?(ssrc, %State{linking_buffers: lb}), do: Map.has_key?(lb, ssrc)

  defp new_stream?(ssrc, pads), do: not Map.has_key?(pads, ssrc)
end
