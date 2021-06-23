defmodule Membrane.RTP.JitterBuffer.StatsEvent do
  @derive Membrane.EventProtocol
  @enforce_keys [:stats]
  defstruct @enforce_keys
end
