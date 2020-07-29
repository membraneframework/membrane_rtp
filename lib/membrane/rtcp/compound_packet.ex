defmodule Membrane.RTCP.CompoundPacket do
  @moduledoc """
  Parses compound RTCP packets into a list of subpackets.
  """

  alias Membrane.RTCP.{Header, Packet}

  defstruct [:packets]

  @type t :: %__MODULE__{packets: [Packet.t()]}

  @spec to_binary(t()) :: binary()
  def to_binary(%__MODULE__{packets: packets}) do
    packets
    |> Enum.map(&Packet.to_binary/1)
    |> Enum.join()
  end

  @spec parse(binary()) :: {:ok, t()} | {:error, any()}
  def parse(compound_packet) do
    with {:ok, packets} <- do_parse(compound_packet, []) do
      {:ok, %__MODULE__{packets: packets}}
    end
  end

  defp do_parse(<<>>, acc), do: {:ok, Enum.reverse(acc)}

  defp do_parse(<<raw_header::binary-size(4), body_and_rest::binary>>, packets) do
    with {:ok, header} <- Header.parse(raw_header),
         # length includes raw_header size
         body_size = header.length - 4,
         <<body::binary-size(body_size), rest::binary>> <- body_and_rest,
         body = Packet.strip_padding(body, header.padding?),
         {:ok, packet} <- Packet.parse_body(body, header) do
      do_parse(rest, [packet | packets])
    else
      {:error, _reason} = err -> err
      _unmatched_binary -> {:error, :invalid_compound_packet}
    end
  end
end
