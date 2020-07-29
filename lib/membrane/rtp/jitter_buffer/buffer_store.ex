defmodule Membrane.RTP.JitterBuffer.BufferStore do
  @moduledoc false

  # Store for RTP packets. Packets are stored in `Heap` ordered by packet index. Packet index is
  # defined in RFC 3711 (SRTP) as: 2^16 * rollover count + sequence number.

  # ## Fields
  #   - `rollover_count` - count of all performed rollovers (cycles of sequence number)
  #   - `heap` - contains records containing buffers
  #   - `prev_index` - index of the last packet that has been served
  #   - `end_index` - the highest index in the buffer so far, mapping to the most recently produced
  #                   RTP packet placed in JitterBuffer

  use Bunch
  alias Membrane.{Buffer, RTP}
  alias Membrane.RTP.JitterBuffer
  alias Membrane.RTP.JitterBuffer.Record

  @seq_number_limit 65_536

  defstruct received: 0,
            base_index: nil,
            prev_index: nil,
            end_index: nil,
            heap: Heap.new(&Record.rtp_comparator/2),
            set: MapSet.new(),
            rollover_count: 0

  @type t :: %__MODULE__{
          received: non_neg_integer(),
          base_index: JitterBuffer.packet_index() | nil,
          prev_index: JitterBuffer.packet_index() | nil,
          end_index: JitterBuffer.packet_index() | nil,
          heap: Heap.t(),
          set: MapSet.t(),
          rollover_count: non_neg_integer()
        }

  @typedoc """
  An atom describing an error that may happen during insertion.
  """
  @type insert_error :: :late_packet

  @typedoc """
  An atom describing an error that may happen when fetching a buffer
  from the Store.
  """
  @type get_buffer_error :: :not_present

  @doc """
  Inserts buffer into the Store.

  Every subsequent buffer must have sequence number Bigger than the previously returned
  one or be part of rollover.
  """
  @spec insert_buffer(t(), Buffer.t()) :: {:ok, t()} | {:error, insert_error()}
  def insert_buffer(store, %Buffer{metadata: %{rtp: %{sequence_number: seq_num}}} = buffer) do
    do_insert_buffer(%__MODULE__{store | received: store.received + 1}, buffer, seq_num)
  end

  @spec do_insert_buffer(t(), Buffer.t(), RTP.Header.sequence_number_t()) ::
          {:ok, t()} | {:error, insert_error()}
  defp do_insert_buffer(%__MODULE__{prev_index: nil} = store, buffer, 0) do
    store = add_record(store, Record.new(buffer, @seq_number_limit))
    {:ok, %__MODULE__{store | prev_index: @seq_number_limit - 1, base_index: 0}}
  end

  defp do_insert_buffer(%__MODULE__{prev_index: nil} = store, buffer, seq_num) do
    store = add_record(store, Record.new(buffer, seq_num))
    {:ok, %__MODULE__{store | prev_index: seq_num - 1, base_index: seq_num}}
  end

  defp do_insert_buffer(
         %__MODULE__{prev_index: prev_index, rollover_count: roc} = store,
         buffer,
         seq_num
       ) do
    index =
      case from_which_cycle(prev_index, seq_num) do
        :current -> seq_num + roc * @seq_number_limit
        :prev -> seq_num + (roc - 1) * @seq_number_limit
        :next -> seq_num + (roc + 1) * @seq_number_limit
      end

    # TODO: Consider taking some action if the gap between indices is too big
    if is_fresh_packet?(prev_index, index) do
      record = Record.new(buffer, index)
      {:ok, add_record(store, record)}
    else
      {:error, :late_packet}
    end
  end

  @doc """
  Calculates size of the Store.

  Size is calculated by counting `slots` between youngest (buffer with
  smallest sequence number) and oldest buffer.

  If Store has buffers [1,2,10] its size would be 10.
  """
  @spec size(__MODULE__.t()) :: number()
  def size(store)
  def size(%__MODULE__{heap: %Heap{data: nil}}), do: 0

  def size(%__MODULE__{prev_index: nil, end_index: last, heap: heap}) do
    size = if Heap.size(heap) == 1, do: 1, else: last - Heap.root(heap).index + 1
    size
  end

  def size(%__MODULE__{prev_index: prev_index, end_index: end_index}) do
    end_index - prev_index
  end

  @doc """
  Shifts the store to the buffer with the next sequence number.

  If this buffer is present, it will be returned.
  Otherwise it will be treated as late and rejected on attempt to insert into the store.
  """
  @spec shift(t) :: {Record.t() | nil, t}
  def shift(store)

  def shift(%__MODULE__{prev_index: nil} = store) do
    {nil, store}
  end

  def shift(%__MODULE__{prev_index: prev_index, heap: heap, set: set} = store) do
    record = Heap.root(heap)

    expected_next_index = prev_index + 1

    {result, store} =
      if record != nil and record.index == expected_next_index do
        updated_heap = Heap.pop(heap)
        updated_set = MapSet.delete(set, record.index)

        updated_store = %__MODULE__{store | heap: updated_heap, set: updated_set}

        {record, updated_store}
      else
        # TODO: instead of nil use expected_next_index to put in Discontinuity metadata
        #       after https://github.com/membraneframework/membrane-core/issues/238 is done.
        {nil, store}
      end

    {result, bump_prev_index(store)}
  end

  @doc """
  Shifts the store until the first gap in sequence numbers of records
  """
  @spec shift_ordered(t) :: {[Record.t() | nil], t}
  def shift_ordered(store) do
    shift_while(store, fn %__MODULE__{prev_index: prev_index}, %Record{index: index} ->
      index == prev_index + 1
    end)
  end

  @doc """
  Shifts the store as long as it contains a buffer with the timestamp older than provided duration
  """
  @spec shift_older_than(t, Membrane.Time.t()) :: {[Record.t() | nil], t}
  def shift_older_than(store, max_age) do
    max_age_timestamp = Membrane.Time.monotonic_time() - max_age

    shift_while(store, fn _store, %Record{timestamp: timestamp} ->
      timestamp <= max_age_timestamp
    end)
  end

  @doc """
  Returns all buffers that are stored in the `BufferStore`.
  """
  @spec dump(t()) :: [Record.t()]
  def dump(%__MODULE__{} = store) do
    {records, _store} = shift_while(store, fn _store, _record -> true end)
    records
  end

  @doc """
  Returns timestamp (time of insertion) of a buffer with lowest index
  """
  @spec first_record_timestamp(t()) :: Membrane.Time.t() | nil
  def first_record_timestamp(%__MODULE__{heap: heap}) do
    case Heap.root(heap) do
      %Record{timestamp: time} -> time
      _no_record -> nil
    end
  end

  defp is_fresh_packet?(prev_index, index), do: index > prev_index

  @spec from_which_cycle(JitterBuffer.packet_index(), RTP.Header.sequence_number_t()) ::
          :current | :next | :prev
  def from_which_cycle(prev_index, seq_num) do
    prev_seq_num = rem(prev_index, @seq_number_limit)

    # calculate the distance between prev_seq_num and new seq_num assuming it comes from:
    # a) current cycle
    distance_if_current = abs(prev_seq_num - seq_num)
    # b) previous cycle
    distance_if_prev = abs(prev_seq_num - (seq_num - @seq_number_limit))
    # c) next cycle
    distance_if_next = abs(prev_seq_num - (seq_num + @seq_number_limit))

    [
      {:current, distance_if_current},
      {:next, distance_if_next},
      {:prev, distance_if_prev}
    ]
    |> Enum.min_by(fn {_atom, distance} -> distance end)
    ~> ({result, _value} -> result)
  end

  @spec shift_while(t, (t, Record.t() -> boolean), [Record.t() | nil]) ::
          {[Record.t() | nil], t}
  defp shift_while(%__MODULE__{heap: heap} = store, fun, acc \\ []) do
    heap
    |> Heap.root()
    |> case do
      nil ->
        {Enum.reverse(acc), store}

      record ->
        if fun.(store, record) do
          {record, store} = shift(store)
          shift_while(store, fun, [record | acc])
        else
          {Enum.reverse(acc), store}
        end
    end
  end

  defp add_record(%__MODULE__{heap: heap, set: set} = store, %Record{} = record) do
    if set |> MapSet.member?(record.index) do
      store
    else
      %__MODULE__{store | heap: Heap.push(heap, record), set: MapSet.put(set, record.index)}
      |> update_end_index(record.index)
    end
  end

  defp bump_prev_index(%{prev_index: prev, rollover_count: roc} = store)
       when rem(prev + 1, @seq_number_limit) == 0,
       do: %__MODULE__{store | prev_index: prev + 1, rollover_count: roc + 1}

  defp bump_prev_index(store), do: %__MODULE__{store | prev_index: store.prev_index + 1}

  defp update_end_index(%__MODULE__{end_index: last} = store, added_index)
       when added_index > last or last == nil,
       do: %__MODULE__{store | end_index: added_index}

  defp update_end_index(%__MODULE__{end_index: last} = store, added_index)
       when last >= added_index,
       do: store
end
