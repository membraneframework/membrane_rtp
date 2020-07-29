defmodule Membrane.RTP.JitterBufferTest do
  use ExUnit.Case, async: true

  alias Membrane.RTP.BufferFactory
  alias Membrane.RTP.JitterBuffer
  alias Membrane.RTP.JitterBuffer.{BufferStore, Record, State}

  @base_seq_number 50

  setup_all do
    buffer = BufferFactory.sample_buffer(@base_seq_number)
    # {:ok, store} = BufferStore.insert_buffer(%BufferStore{}, buffer)
    state = %State{
      clock_rate: 10_000,
      store: %BufferStore{},
      latency: 10 |> Membrane.Time.milliseconds()
    }

    [state: state, buffer: buffer]
  end

  describe "When JitterBuffer is in waiting state" do
    setup %{state: state} do
      [state: %{state | waiting?: true}]
    end

    test "start of stream starts timer that changes state", %{state: state} do
      assert {:ok, state} = JitterBuffer.handle_start_of_stream(:input, %{}, state)
      assert_receive message, (state.latency |> Membrane.Time.to_milliseconds()) + 2

      assert {{:ok, redemand: :output}, final_state} =
               JitterBuffer.handle_other(message, %{}, state)

      assert final_state.waiting? == false
    end

    test "any new buffer is kept without redemand", %{state: state, buffer: buffer} do
      assert BufferStore.dump(state.store) == []
      assert {:ok, state} = JitterBuffer.handle_process(:input, buffer, nil, state)

      assert %State{store: store} = state
      assert {%Record{buffer: ^buffer}, new_store} = BufferStore.shift(store)
      assert BufferStore.dump(new_store) == []
    end

    test "jitter stats are updated", %{state: state, buffer: buffer} do
      ts = ~U[2020-06-19 19:06:00Z] |> DateTime.to_unix() |> Membrane.Time.seconds()

      timestamped_buf = put_in(buffer.metadata[:arrival_ts], ts)
      assert {:ok, state} = JitterBuffer.handle_process(:input, timestamped_buf, nil, state)
      assert state.stats_acc.jitter == 0.0

      assert state.stats_acc.last_transit ==
               Membrane.Time.to_seconds(ts) * state.clock_rate -
                 timestamped_buf.metadata.rtp.timestamp

      buffer = BufferFactory.sample_buffer(@base_seq_number + 1)

      arrival_ts_increment =
        div(BufferFactory.timestamp_increment(), state.clock_rate) |> Membrane.Time.seconds()

      packet_delay = 1 |> Membrane.Time.seconds()

      timestamped_buf =
        put_in(buffer.metadata[:arrival_ts], ts + arrival_ts_increment + packet_delay)

      assert {:ok, state} = JitterBuffer.handle_process(:input, timestamped_buf, nil, state)

      # 16 is defined by RFC
      assert state.stats_acc.jitter ==
               div(Membrane.Time.to_seconds(packet_delay) * state.clock_rate, 16)

      assert state.stats_acc.last_transit ==
               Membrane.Time.to_seconds(ts + arrival_ts_increment + packet_delay) *
                 state.clock_rate -
                 timestamped_buf.metadata.rtp.timestamp
    end
  end

  describe "When new buffer arrives when not waiting and already pushed some buffer" do
    setup %{state: state} do
      store = %{state.store | prev_index: @base_seq_number - 1}
      [state: %{state | waiting?: false, store: store}]
    end

    test "outputs it immediately if it is in order", %{state: state, buffer: buffer} do
      assert {{:ok, buffer: {:output, ^buffer}, redemand: :output}, state} =
               JitterBuffer.handle_process(:input, buffer, nil, state)

      assert %JitterBuffer.State{store: store} = state
      assert BufferStore.dump(store) == []
    end

    test "refuses to add that packet when it comes too late", %{state: state} do
      late_buffer = BufferFactory.sample_buffer(@base_seq_number - 2)

      assert {{:ok, redemand: :output}, new_state} =
               JitterBuffer.handle_process(:input, late_buffer, nil, state)

      # assert nothing changed except for stats
      assert %{new_state | stats_acc: state.stats_acc} == state
    end

    test "adds it and when it fills the gap, returns all buffers in order", %{state: state} do
      first_buffer = BufferFactory.sample_buffer(@base_seq_number)
      second_buffer = BufferFactory.sample_buffer(@base_seq_number + 1)
      third_buffer = BufferFactory.sample_buffer(@base_seq_number + 2)

      store =
        with store = %BufferStore{state.store | prev_index: @base_seq_number - 1},
             {:ok, store} <- BufferStore.insert_buffer(store, second_buffer),
             {:ok, store} <- BufferStore.insert_buffer(store, third_buffer) do
          store
        end

      state = %State{state | store: store}

      assert {{:ok, commands}, %State{store: result_store}} =
               JitterBuffer.handle_process(:input, first_buffer, nil, state)

      buffers = commands |> Keyword.get_values(:buffer) |> Enum.map(fn {:output, buf} -> buf end)

      assert [^first_buffer, ^second_buffer, ^third_buffer] = buffers
      assert BufferStore.dump(result_store) == []
    end
  end

  describe "When latency pasess without filling the gap, JitterBuffer" do
    test "outputs discontinuity and late buffer", %{state: state, buffer: buffer} do
      store = %BufferStore{state.store | prev_index: @base_seq_number - 2}
      state = %{state | store: store, waiting?: false}

      assert {{:ok, commands}, state} = JitterBuffer.handle_process(:input, buffer, nil, state)
      assert commands |> Keyword.get(:buffer) == nil
      assert is_reference(state.max_latency_timer)
      assert_receive message, (state.latency |> Membrane.Time.to_milliseconds()) + 20

      assert {{:ok, actions}, state} = JitterBuffer.handle_other(message, %{}, state)

      assert [event: event, buffer: buffer_action, redemand: :output] = actions
      assert event == {:output, %Membrane.Event.Discontinuity{}}
      assert buffer_action == {:output, buffer}
    end
  end

  describe "When event arrives" do
    test "dumps store if event was end of stream", %{state: state, buffer: buffer} do
      store = %BufferStore{state.store | prev_index: @base_seq_number - 2, base_index: 0}
      {:ok, store} = BufferStore.insert_buffer(store, buffer)
      state = %{state | store: store}
      assert {{:ok, actions}, r_state} = JitterBuffer.handle_end_of_stream(:input, nil, state)

      assert [event: event, buffer: buffer_action, end_of_stream: :output] = actions
      assert event == {:output, %Membrane.Event.Discontinuity{}}
      assert buffer_action == {:output, buffer}
    end
  end
end
