defmodule Membrane.RTP.Session.ReceiveBin do
  # TODO: Either rename and add sending support or wrap in a bin handling both receiving and sending
  @moduledoc """
  A bin handling the receive part of RTP session.

  Consumes one or more RTP streams on each input and outputs a stream from one SSRC on each output.

  Every stream is parsed and then (based on SSRC field) RTP streams are separated, depacketized and sent further.
  It notifies its parent about each new stream with a notification of the format `{:new_rtp_stream, ssrc, payload_type}`.
  Parent should then connect to this bin's dynamic output pad instance that will
  have an id == `ssrc`.
  """
  use Membrane.Bin

  alias Membrane.ParentSpec
  alias Membrane.{RTCP, RTP}
  alias Membrane.RTP.Packet.PayloadType

  require Bitwise

  @ssrc_boundaries 2..(Bitwise.bsl(1, 32) - 1)

  @bin_input_buffer_params [warn_size: 250, fail_size: 500]

  @known_depayloaders %{
    H264: Membrane.RTP.H264.Depayloader,
    MPA: Membrane.RTP.MPEGAudio.Depayloader
  }

  def_options fmt_mapping: [
                spec: %{RTP.payload_type_t() => {RTP.encoding_name_t(), RTP.clock_rate_t()}},
                default: %{},
                description: "Mapping of the custom payload types ( > 95)"
              ],
              custom_depayloaders: [
                spec: %{RTP.encoding_name_t() => module()},
                default: %{},
                description: "Mapping from a payload type to a custom depayloader module"
              ],
              rtcp_interval: [
                type: :time,
                default: 5 |> Membrane.Time.seconds(),
                description: "Interval between sending subseqent RTCP receiver reports."
              ],
              receiver_ssrc_generator: [
                type: :function,
                spec:
                  (local_ssrcs :: [RTP.ssrc_t()], remote_ssrcs :: [RTP.ssrc_t()] ->
                     ssrc :: RTP.ssrc_t()),
                default: &__MODULE__.generate_receiver_ssrc/2,
                description: """
                Function generating receiver SSRCs. Default one generates random SSRC
                that is not in `local_ssrcs` nor `remote_ssrcs`.
                """
              ]

  @doc false
  @spec generate_receiver_ssrc(local_ssrcs :: [RTP.ssrc_t()], remote_ssrcs :: [RTP.ssrc_t()]) ::
          RTP.ssrc_t()
  def generate_receiver_ssrc(local_ssrcs, remote_ssrcs) do
    fn -> Enum.random(@ssrc_boundaries) end
    |> Stream.repeatedly()
    |> Enum.find(&(&1 not in local_ssrcs and &1 not in remote_ssrcs))
  end

  def_input_pad :input, demand_unit: :buffers, caps: :any, availability: :on_request
  def_input_pad :rtcp_input, demand_unit: :buffers, caps: :any, availability: :on_request

  def_output_pad :output, demand_unit: :buffers, caps: :any, availability: :on_request
  def_output_pad :rtcp_output, demand_unit: :buffers, caps: RTCP, availability: :on_request

  defmodule State do
    @moduledoc false

    defstruct fmt_mapping: %{},
              ssrc_pt_mapping: %{},
              depayloaders: nil,
              ssrcs: %{},
              rtcp_interval: nil,
              receiver_reporter?: false,
              receiver_ssrc_generator: nil
  end

  @impl true
  def handle_init(options) do
    children = [ssrc_router: RTP.SSRCRouter]
    links = []

    spec = %ParentSpec{children: children, links: links}

    depayloaders = Map.merge(@known_depayloaders, options.custom_depayloaders)

    {{:ok, spec: spec},
     %State{
       fmt_mapping: options.fmt_mapping,
       depayloaders: depayloaders,
       rtcp_interval: options.rtcp_interval,
       receiver_ssrc_generator: options.receiver_ssrc_generator
     }}
  end

  @impl true
  def handle_pad_added(Pad.ref(:input, ref) = pad, _ctx, state) do
    parser_ref = {:rtp_parser, ref}

    children = [{parser_ref, RTP.Parser}]

    links = [
      link_bin_input(pad)
      |> via_in(:input, buffer: @bin_input_buffer_params)
      |> to(parser_ref)
      |> to(:ssrc_router)
    ]

    new_spec = %ParentSpec{children: children, links: links}

    {{:ok, spec: new_spec}, state}
  end

  @impl true
  def handle_pad_added(Pad.ref(:rtcp_input, ref) = pad, _ctx, state) do
    parser_ref = {:rtcp_parser, ref}

    children = [{parser_ref, RTCP.Parser}]

    links = [
      link_bin_input(pad)
      |> via_in(:input, buffer: @bin_input_buffer_params)
      |> to(parser_ref)
    ]

    new_spec = %ParentSpec{children: children, links: links}

    {{:ok, spec: new_spec}, state}
  end

  @impl true
  def handle_pad_added(Pad.ref(:output, ssrc) = pad, _ctx, state) do
    {pt_name, clock_rate} = state.ssrc_pt_mapping |> Map.get(ssrc)

    depayloader =
      case state.depayloaders[pt_name] do
        nil -> raise "Cannot find depayloader for payload type #{pt_name}"
        depayloader -> depayloader
      end

    rtp_stream_name = {:rtp_stream_bin, ssrc}

    new_children = [
      {rtp_stream_name,
       %RTP.StreamReceiveBin{depayloader: depayloader, ssrc: ssrc, clock_rate: clock_rate}}
    ]

    new_links = [
      link(:ssrc_router)
      |> via_out(Pad.ref(:output, ssrc))
      |> to(rtp_stream_name)
      |> to_bin_output(pad)
    ]

    new_spec = %ParentSpec{children: new_children, links: new_links}
    state = %{state | ssrcs: add_ssrc(ssrc, state.ssrcs, state.receiver_ssrc_generator)}
    {{:ok, spec: new_spec}, state}
  end

  @impl true
  def handle_pad_added(Pad.ref(:rtcp_output, _ref) = pad, _ctx, state) do
    new_children = [receiver_reporter: %RTCP.ReceiverReporter{interval: state.rtcp_interval}]
    new_links = [link(:receiver_reporter) |> to_bin_output(pad)]
    new_spec = %ParentSpec{children: new_children, links: new_links}
    {{:ok, spec: new_spec}, %{state | receiver_reporter?: true}}
  end

  @impl true
  def handle_pad_removed(Pad.ref(:input, ref), _ctx, state) do
    {{:ok, remove_child: {:rtp_parser, ref}}, state}
  end

  @impl true
  def handle_pad_removed(Pad.ref(:rtcp_input, ref), _ctx, state) do
    {{:ok, remove_child: {:rtcp_parser, ref}}, state}
  end

  @impl true
  def handle_pad_removed(Pad.ref(:output, ssrc), _ctx, state) do
    # TODO: parent may not know when to unlink, we need to timout SSRCs and notify about that and BYE packets over RTCP
    state = %{state | ssrcs: Map.delete(state.ssrcs, ssrc)}
    {{:ok, remove_child: {:rtp_stream_bin, ssrc}}, state}
  end

  @impl true
  def handle_pad_removed(Pad.ref(:rtcp_output, _ref), _ctx, state) do
    {{:ok, remove_child: :receiver_reporter}, %{state | receiver_reporter?: false}}
  end

  @impl true
  def handle_notification({:new_rtp_stream, ssrc, pt_num}, :ssrc_router, state) do
    %State{ssrc_pt_mapping: ssrc_pt_mapping, fmt_mapping: fmt_map} = state

    {pt_name, clock_rate} =
      if PayloadType.is_dynamic(pt_num) do
        unless Map.has_key?(fmt_map, pt_num) do
          raise "Unknown RTP payload type #{pt_num}"
        end

        fmt_map[pt_num]
      else
        {PayloadType.get_encoding_name(pt_num), PayloadType.get_clock_rate(pt_num)}
      end

    if pt_name == nil do
      raise "Unknown RTP payload type #{pt_num}"
    end

    new_ssrc_pt_mapping = ssrc_pt_mapping |> Map.put(ssrc, {pt_name, clock_rate})

    state = %{state | ssrc_pt_mapping: new_ssrc_pt_mapping}
    {{:ok, notify: {:new_rtp_stream, ssrc, pt_name}}, state}
  end

  @impl true
  def handle_notification({:received_rtcp, rtcp, timestamp}, {:rtcp_parser, _ref}, state) do
    # TODO: handle RTCP reports properly
    actions =
      if state.receiver_reporter?,
        do: [forward: {:receiver_reporter, {:remote_report, rtcp, timestamp}}],
        else: []

    {{:ok, actions}, state}
  end

  @impl true
  def handle_notification(:send_stats, :receiver_reporter, state) do
    remote_ssrcs = state.ssrcs |> Map.keys() |> MapSet.new()

    forwards =
      [receiver_reporter: {:ssrcs_to_report, remote_ssrcs}] ++
        Enum.map(remote_ssrcs, &{{:rtp_stream_bin, &1}, :send_stats})

    actions = Enum.map(forwards, &{:forward, &1})
    {{:ok, actions}, state}
  end

  @impl true
  def handle_notification({:jitter_buffer_stats, stats}, {:rtp_stream_bin, remote_ssrc}, state) do
    actions =
      case Map.fetch(state.ssrcs, remote_ssrc) do
        {:ok, local_ssrc} ->
          stats_msg = {:jitter_buffer_stats, {local_ssrc, remote_ssrc, stats}}
          [forward: {:receiver_reporter, stats_msg}]

        :error ->
          []
      end

    {{:ok, actions}, state}
  end

  defp add_ssrc(remote_ssrc, ssrcs, generator) do
    local_ssrc = generator.([remote_ssrc | Map.keys(ssrcs)], Map.values(ssrcs))
    Map.put(ssrcs, remote_ssrc, local_ssrc)
  end
end
