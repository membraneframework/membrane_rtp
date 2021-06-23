defmodule Membrane.RTCPEvent do
  @derive Membrane.EventProtocol

  @enforce_keys [:rtcp]

  defstruct @enforce_keys ++ [ssrcs: [], arrival_timestamp: nil]
end
