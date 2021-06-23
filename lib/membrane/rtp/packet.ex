defmodule Membrane.RTP.Packet do
  @moduledoc """
  Defines a struct describing an RTP packet and a way to parse and serialize it.
  Based on [RFC3550](https://tools.ietf.org/html/rfc3550#page-13)
  """

  alias Membrane.RTP.{Header, Utils}

  @type t :: %__MODULE__{
          header: Header.t(),
          payload: binary()
        }

  @enforce_keys [:header, :payload]
  defstruct @enforce_keys

  def identify(<<_first_byte, _marker::1, payload_type::7, _rest::binary>>)
      when payload_type in 64..95,
      do: :rtcp

  def identify(_packet), do: :rtp

  @spec serialize(t, align_to: pos_integer()) :: binary
  def serialize(%__MODULE__{} = packet, [align_to: align_to] \\ [align_to: 1]) do
    %__MODULE__{header: header, payload: payload} = packet
    %Header{version: 2} = header
    has_padding = 0
    has_extension = if header.extension, do: 1, else: 0
    marker = if header.marker, do: 1, else: 0
    csrcs = Enum.map_join(header.csrcs, &<<&1::32>>)

    serialized =
      <<header.version::2, has_padding::1, has_extension::1, length(header.csrcs)::4, marker::1,
        header.payload_type::7, header.sequence_number::16, header.timestamp::32, header.ssrc::32,
        csrcs::binary, serialize_header_extension(header.extension)::binary, payload::binary>>

    case Utils.align(serialized, align_to) do
      {serialized, 0} ->
        serialized

      {serialized, _padding} ->
        <<pre::2, _has_padding::1, post::bitstring>> = serialized
        <<pre::2, 1::1, post::bitstring>>
    end
  end

  defp serialize_header_extension(nil) do
    <<>>
  end

  defp serialize_header_extension(%Header.Extension{data: data} = extension)
       when byte_size(data) |> rem(4) == 0 do
    <<extension.profile_specific::16, byte_size(data) |> div(4)::16, data::binary>>
  end

  @spec parse(binary()) :: {:ok, t()} | {:error, :wrong_version | :malformed_packet}
  def parse(<<version::2, _::bitstring>>) when version != 2,
    do: {:error, :wrong_version}

  def parse(
        <<version::2, has_padding::1, has_extension::1, csrcs_cnt::4, marker::1, payload_type::7,
          sequence_number::16, timestamp::32, ssrc::32, csrcs::binary-size(csrcs_cnt)-unit(32),
          rest::binary>>
      ) do
    with {:ok, {extension, payload}} <- parse_header_extension(rest, has_extension == 1),
         {:ok, {payload, _padding}} = Utils.strip_padding(payload, has_padding == 1) do
      header = %Header{
        version: version,
        marker: marker == 1,
        ssrc: ssrc,
        sequence_number: sequence_number,
        payload_type: payload_type,
        timestamp: timestamp,
        csrcs: for(<<csrc::32 <- csrcs>>, do: csrc),
        extension: extension
      }

      {:ok, %__MODULE__{header: header, payload: payload}}
    else
      :error -> {:error, :malformed_packet}
    end
  end

  def parse(_binary), do: {:error, :malformed_packet}

  defp parse_header_extension(binary, header_present?)
  defp parse_header_extension(binary, false), do: {:ok, {nil, binary}}

  defp parse_header_extension(
         <<profile_specific::16, data_len::16, data::binary-size(data_len)-unit(32),
           rest::binary>>,
         true
       ) do
    extension = %Header.Extension{profile_specific: profile_specific, data: data}
    {:ok, {extension, rest}}
  end

  defp parse_header_extension(_binary, true), do: :error
end
