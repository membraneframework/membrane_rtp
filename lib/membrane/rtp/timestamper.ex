defmodule Membrane.RTP.Timestamper do
  @moduledoc """
  An element adding timestamps to buffers based on timestamps RTP metadata
  """
  use Membrane.Filter
  use Membrane.Log, tags: :timestamper

  def_input_pad :input, demand_unit: :buffers, caps: :any
  def_output_pad :output, caps: :any

  def_options clock_rate: [], init_timestamp: [default: nil]

  @impl true
  def handle_init(opts) do
    {:ok, opts |> Map.from_struct()}
  end

  @impl true
  def handle_demand(:output, size, :buffers, _ctx, state) do
    {{:ok, demand: {:input, size}}, state}
  end

  @impl true
  def handle_process(:input, buffer, _ctx, state) do
    use Ratio
    rtp_timestamp = buffer.metadata.rtp.timestamp

    {init_timestamp, state} =
      Bunch.Map.get_updated!(state, :init_timestamp, &(&1 || rtp_timestamp))

    timestamp = (rtp_timestamp - init_timestamp) * state.clock_rate
    buffer = Bunch.Struct.put_in(buffer, [:metadata, :timestamp], timestamp)
    {{:ok, buffer: {:output, buffer}}, state}
  end
end
