defmodule Membrane.RTP.Packet do
  @moduledoc """
  Defines a struct describing an RTP packet and a way to parse it.
  Based on [RFC3550](https://tools.ietf.org/html/rfc3550#page-13)
  """

  alias Membrane.RTP.{Header, Packet}

  @type t :: %__MODULE__{
          header: Header.t(),
          payload: binary()
        }

  defstruct [
    :header,
    :payload
  ]

  @type error_reason() :: :wrong_version | :packet_malformed

  @spec parse(binary()) :: {:ok, Packet.t()} | {:error, error_reason()}
  def parse(<<version::2, _::6, _::binary>>) when version != 2,
    do: {:error, :wrong_version}

  def parse(bytes) when byte_size(bytes) < 4 * 3, do: {:error, :packet_malformed}

  def parse(
        <<v::2, p::1, x::1, cc::4, m::1, payload_type::7, sequence_number::16, timestamp::32,
          ssrc::32, rest::binary>>
      ) do
    {parsed_csrc, rest} = extract_csrcs(rest, cc)
    {extension_header, payload} = extract_extension_header(x, rest)
    padding? = extract_boolean(p)
    payload = strip_padding(payload, padding?)

    packet = %Packet{
      header: %Header{
        version: v,
        marker: extract_boolean(m),
        padding: padding?,
        extension_header: extract_boolean(x),
        csrc_count: cc,
        ssrc: ssrc,
        sequence_number: sequence_number,
        payload_type: payload_type,
        timestamp: timestamp,
        csrcs: parsed_csrc,
        extension_header_data: extension_header
      },
      payload: payload
    }

    {:ok, packet}
  end

  defp extract_csrcs(data, count, acc \\ [])
  defp extract_csrcs(data, 0, acc), do: {acc, data}

  defp extract_csrcs(<<csrc::32, rest::binary>>, count, acc),
    do: extract_csrcs(rest, count - 1, [csrc | acc])

  defp extract_extension_header(is_header_present, data)
  defp extract_extension_header(0, data), do: {nil, data}

  defp extract_extension_header(1, binary_data) do
    <<profile_specific::16, len::16, header_ext::binary-size(len), rest::binary>> = binary_data

    extension_data = %Header.Extension{
      profile_specific: profile_specific,
      header_extension: header_ext
    }

    {extension_data, rest}
  end

  defp extract_boolean(read_value)
  defp extract_boolean(1), do: true
  defp extract_boolean(0), do: false

  @spec strip_padding(payload :: binary(), has_padding :: boolean()) :: binary()
  def strip_padding(payload, false), do: payload

  def strip_padding(payload, true) do
    padding_size = :binary.last(payload)
    payload_size = byte_size(payload) - padding_size
    <<stripped_payload::binary-size(payload_size), _::binary-size(padding_size)>> = payload
    stripped_payload
  end
end
