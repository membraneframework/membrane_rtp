defmodule Membrane.RTCP.Header do
  @moduledoc """
  Struct describing 32-bit header common to all RTCP packets
  """

  @enforce_keys [:packet_type, :packet_specific]
  defstruct @enforce_keys

  @type packet_type_t :: 200..204

  @type packet_specific_t :: non_neg_integer()

  @type t :: %__MODULE__{
          packet_specific: packet_specific_t(),
          packet_type: packet_type_t()
        }

  @spec parse(binary()) ::
          {:ok, %{header: t(), padding?: boolean, length: pos_integer}}
          | :error
  def parse(<<2::2, padding::1, packet_specific::5, pt::8, length::16>>) do
    {:ok,
     %{
       header: %__MODULE__{
         packet_specific: packet_specific,
         packet_type: pt
       },
       padding?: padding == 1,
       length: length * 4
     }}
  end

  def parse(_) do
    :error
  end

  @spec serialize(t(), length: pos_integer(), padding?: boolean()) :: binary()
  def serialize(%__MODULE__{} = header, opts) do
    padding = if Keyword.get(opts, :padding?), do: 1, else: 0
    length = Keyword.fetch!(opts, :length)
    0 = rem(length, 4)
    <<2::2, padding::1, header.packet_specific::5, header.packet_type::8, div(length, 4)::16>>
  end
end
