defmodule Membrane.RTCP.Packet do
  @moduledoc """
  Functions common to all RTCP Packets
  """

  alias Membrane.RTCP.{
    AppPacket,
    ByePacket,
    FeedbackPacket,
    Header,
    ReceiverReportPacket,
    SdesPacket,
    SenderReportPacket
  }

  alias Membrane.RTP

  @type t ::
          AppPacket.t()
          | ByePacket.t()
          | FeedbackPacket.t()
          | ReceiverReportPacket.t()
          | SenderReportPacket.t()
          | SdesPacket.t()

  @doc """
  Decodes binary with packet body (without header) into packet struct. Used by `parse/1`
  """
  @callback decode(binary(), packet_specific :: Header.packet_specific_t()) ::
              {:ok, struct()} | {:error, atom()}

  @doc """
  Encodes packet struct into the tuple used by `serialize/1`
  """
  @callback encode(struct()) ::
              {body :: binary(), packet_type :: Header.packet_type_t(),
               packet_specific :: Header.packet_specific_t()}

  @packet_type_module BiMap.new(%{
                        200 => SenderReportPacket,
                        201 => ReceiverReportPacket,
                        202 => SdesPacket,
                        203 => ByePacket,
                        204 => AppPacket,
                        206 => FeedbackPacket
                      })

  @doc """
  Converts packet structure into binary
  """
  @spec serialize(t() | [t()]) :: binary()
  def serialize(%packet_module{} = packet) do
    {body, packet_specific} = packet_module.encode(packet)
    packet_type = BiMap.fetch_key!(@packet_type_module, packet_module)

    header =
      %Header{packet_type: packet_type, packet_specific: packet_specific}
      |> Header.serialize(length: byte_size(body))

    header <> body
  end

  def serialize(packets) when is_list(packets) do
    Enum.map_join(packets, &serialize/1)
  end

  @spec parse(binary()) :: {:ok, [t()]} | {:error, any()}
  def parse(packets) do
    do_parse(packets, [])
  end

  defp do_parse(<<>>, acc), do: {:ok, Enum.reverse(acc)}

  defp do_parse(<<raw_header::binary-size(4), body_and_rest::binary>>, acc) do
    with {:ok, %{header: header, length: length, padding?: padding?}} <- Header.parse(raw_header),
         <<body::binary-size(length), rest::binary>> <- body_and_rest,
         {:ok, {body, _padding}} <- RTP.Utils.strip_padding(body, padding?),
         {:ok, packet_module} <- BiMap.fetch(@packet_type_module, header.packet_type),
         {:ok, packet} <- packet_module.decode(body, header.packet_specific) do
      do_parse(rest, [packet | acc])
    else
      {:error, reason} -> {:error, reason}
      _error -> {:error, :malformed_packet}
    end
  end

  defp do_parse(_binary, _acc), do: {:error, :malformed_packet}
end
