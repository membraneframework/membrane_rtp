defmodule Membrane.RTP.PipelineTest do
  use ExUnit.Case

  import Membrane.Testing.Assertions

  alias Membrane.Buffer
  alias Membrane.RTP.{Parser, Fixtures}
  alias Membrane.Testing.{Source, Pipeline, Sink}

  @buffer_receive_timeout 1000

  test "Pipeline decodes set of RTP packets" do
    test_data_base = 1..100
    test_data = Fixtures.fake_packet_list(test_data_base)

    {:ok, pipeline} =
      Pipeline.start_link(%Pipeline.Options{
        elements: [
          source: %Source{output: test_data},
          parser: Parser,
          sink: %Sink{}
        ]
      })

    Pipeline.play(pipeline)

    Enum.each(test_data_base, fn _counter ->
      assert_sink_buffer(pipeline, :sink, %Buffer{}, @buffer_receive_timeout)
    end)
  end
end
