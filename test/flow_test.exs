alias Experimental.{GenStage, Flow}

defmodule FlowTest do
  use ExUnit.Case, async: true

  doctest Flow

  defmodule Counter do
    use GenStage

    def init(counter) do
      {:producer, counter}
    end

    def handle_demand(demand, counter) when demand > 0 do
      # If the counter is 3 and we ask for 2 items, we will
      # emit the items 3 and 4, and set the state to 5.
      events = Enum.to_list(counter..counter+demand-1)
      {:noreply, events, counter + demand}
    end
  end

  defmodule Forwarder do
    use GenStage

    def init(parent) do
      {:consumer, parent}
    end

    def handle_events(events, _from, parent) do
      send parent, {:consumed, events}
      {:noreply, [], parent}
    end
  end

  describe "errors" do
    test "on multiple reduce calls" do
      assert_raise ArgumentError, ~r"cannot call reduce/3 on a flow after another reduce/3 operation", fn ->
        Flow.from_enumerable([1, 2, 3])
        |> Flow.reduce(fn -> 0 end, & &1 + &2)
        |> Flow.reduce(fn -> 0 end, & &1 + &2)
        |> Enum.to_list
      end
    end

    test "on map_state without reduce" do
      assert_raise ArgumentError, ~r"map_state/2 must be called after a reduce/3 operation", fn ->
        Flow.from_enumerable([1, 2, 3])
        |> Flow.map_state(fn x -> x end)
        |> Enum.to_list
      end
    end

    test "on window without computation" do
      assert_raise ArgumentError, ~r"a window was set but no computation is happening on this partition", fn ->
        Flow.from_enumerable([1, 2, 3], window: Flow.Window.fixed(1, :second, & &1))
        |> Enum.to_list
      end
    end
  end

  describe "enumerable-stream" do
    @flow Flow.from_enumerables([[1, 2, 3], [4, 5, 6]], stages: 2)

    test "only sources"  do
      assert @flow |> Enum.sort() == [1, 2, 3, 4, 5, 6]
    end

    test "each/2" do
      parent = self()
      assert @flow |> Flow.each(&send(parent, &1)) |> Enum.sort() ==
             [1, 2, 3, 4, 5, 6]
      assert_received 1
      assert_received 2
      assert_received 3
    end

    test "filter/2" do
      assert @flow |> Flow.filter(&rem(&1, 2) == 0) |> Enum.sort() ==
             [2, 4, 6]
    end

    test "filter_map/3" do
      assert @flow |> Flow.filter_map(&rem(&1, 2) == 0, & &1 * 2) |> Enum.sort() ==
             [4, 8, 12]
    end

    test "flat_map/2" do
      assert @flow |> Flow.flat_map(&[&1, &1]) |> Enum.sort() ==
             [1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6]
    end

    test "map/2" do
      assert @flow |> Flow.map(& &1 * 2) |> Enum.sort() ==
             [2, 4, 6, 8, 10, 12]
    end

    test "reject/2" do
      assert @flow |> Flow.reject(&rem(&1, 2) == 0) |> Enum.sort() ==
             [1, 3, 5]
    end

    test "uniq_by/2" do
      assert @flow |> Flow.uniq_by(&rem(&1, 2)) |> Enum.sort() == [1, 2]
    end

    test "keeps ordering" do
      flow =
        @flow
        |> Flow.filter(&rem(&1, 2) == 0)
        |> Flow.map(fn(x) -> x + 1 end)
        |> Flow.map(fn(x) -> x * 2 end)
      assert Enum.sort(flow) == [6, 10, 14]
    end

    test "start_link/2" do
      parent = self()

      {:ok, _} =
        @flow
        |> Flow.filter(&rem(&1, 2) == 0)
        |> Flow.each(&send(parent, &1))
        |> Flow.start_link()

      assert_receive 2
      assert_receive 4
      assert_receive 6
      refute_received 1
    end

    test "into_stages/3" do
      {:ok, forwarder} = GenStage.start_link(Forwarder, self())

      {:ok, _} =
        @flow
        |> Flow.filter(&rem(&1, 2) == 0)
        |> Flow.into_stages([forwarder])

      assert_receive {:consumed, [2]}
      assert_receive {:consumed, [4, 6]}
    end
  end

  describe "enumerable-unpartioned-stream" do
    @flow Flow.from_enumerables([[1, 2, 3], [4, 5, 6]], stages: 4)

    test "only sources"  do
      assert @flow |> Enum.sort() == [1, 2, 3, 4, 5, 6]
    end

    test "each/2" do
      parent = self()
      assert @flow |> Flow.each(&send(parent, &1)) |> Enum.sort() ==
             [1, 2, 3, 4, 5, 6]
      assert_received 1
      assert_received 2
      assert_received 3
    end

    test "filter/2" do
      assert @flow |> Flow.filter(&rem(&1, 2) == 0) |> Enum.sort() ==
             [2, 4, 6]
    end

    test "filter_map/3" do
      assert @flow |> Flow.filter_map(&rem(&1, 2) == 0, & &1 * 2) |> Enum.sort() ==
             [4, 8, 12]
    end

    test "flat_map/2" do
      assert @flow |> Flow.flat_map(&[&1, &1]) |> Enum.sort() ==
             [1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6]
    end

    test "map/2" do
      assert @flow |> Flow.map(& &1 * 2) |> Enum.sort() ==
             [2, 4, 6, 8, 10, 12]
    end

    test "reject/2" do
      assert @flow |> Flow.reject(&rem(&1, 2) == 0) |> Enum.sort() ==
             [1, 3, 5]
    end

    test "reduce/3" do
      assert @flow |> Flow.reduce(fn -> 0 end, &+/2) |> Flow.map_state(&[&1]) |> Enum.sum() ==
             21
    end

    test "uniq_by/2" do
      assert @flow |> Flow.uniq_by(&rem(&1, 2)) |> Enum.sort() == [1, 2]
    end

    test "keeps ordering" do
      flow =
        @flow
        |> Flow.filter(&rem(&1, 2) == 0)
        |> Flow.map(fn(x) -> x + 1 end)
        |> Flow.map(fn(x) -> x * 2 end)
      assert Enum.sort(flow) == [6, 10, 14]
    end

    test "allows custom windowding" do
      window =
        Flow.Window.fixed(1, :second, fn
          x when x <= 50 -> 0
          x when x <= 100 -> 1_000
        end)

      windows = Flow.from_enumerable(1..100, window: window, stages: 4, max_demand: 5)
                |> Flow.reduce(fn -> 0 end, & &1 + &2)
                |> Flow.emit(:state)
                |> Enum.to_list()
      assert length(windows) == 8
      assert Enum.sum(windows) == 5050
    end

    test "start_link/2" do
      parent = self()

      {:ok, _} =
        @flow
        |> Flow.filter(&rem(&1, 2) == 0)
        |> Flow.each(&send(parent, &1))
        |> Flow.start_link()

      assert_receive 2
      assert_receive 4
      assert_receive 6
      refute_received 1
    end

    test "into_stages/3" do
      {:ok, forwarder} = GenStage.start_link(Forwarder, self())

      {:ok, _} =
        @flow
        |> Flow.filter(&rem(&1, 2) == 0)
        |> Flow.into_stages([forwarder])

      assert_receive {:consumed, [2]}
      assert_receive {:consumed, [4, 6]}
    end
  end

  describe "enumerable-partitioned-stream" do
    @flow Flow.from_enumerables([[1, 2, 3], [4, 5, 6], 7..10], stages: 4)
          |> Flow.partition(stages: 4)

    test "only sources"  do
      assert Flow.from_enumerables([[1, 2, 3], [4, 5, 6], 7..10], stages: 4)
             |> Flow.partition(stages: 4)
             |> Enum.sort() == [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]

      assert Flow.from_enumerables([[1, 2, 3], [4, 5, 6], 7..10], stages: 4)
             |> Flow.partition(stages: 4)
             |> Flow.reduce(fn -> [] end, &[&1 | &2])
             |> Flow.emit(:state)
             |> Enum.map(&Enum.sort/1)
             |> Enum.sort() == [[1, 5, 7, 9], [2, 6, 8], [3, 4], [10]]
    end

    test "each/2" do
      parent = self()
      assert @flow |> Flow.each(&send(parent, &1)) |> Enum.sort() ==
             [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
      assert_received 1
      assert_received 2
      assert_received 3
    end

    test "filter/2" do
      assert @flow |> Flow.filter(&rem(&1, 2) == 0) |> Enum.sort() ==
             [2, 4, 6, 8, 10]
    end

    test "filter_map/3" do
      assert @flow |> Flow.filter_map(&rem(&1, 2) == 0, & &1 * 2) |> Enum.sort() ==
             [4, 8, 12, 16, 20]
    end

    test "flat_map/2" do
      assert @flow |> Flow.flat_map(&[&1, &1]) |> Enum.sort() ==
             [1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10]
    end

    test "map/2" do
      assert @flow |> Flow.map(& &1 * 2) |> Enum.sort() ==
             [2, 4, 6, 8, 10, 12, 14, 16, 18, 20]
    end

    test "reject/2" do
      assert @flow |> Flow.reject(&rem(&1, 2) == 0) |> Enum.sort() ==
             [1, 3, 5, 7, 9]
    end

    test "reduce/3" do
      assert @flow |> Flow.reduce(fn -> 0 end, &+/2) |> Flow.map_state(&[&1]) |> Enum.sort() ==
             [7, 10, 16, 22]

      assert @flow |> Flow.reject(&rem(&1, 2) == 0) |> Flow.reduce(fn -> 0 end, &+/2) |> Flow.map_state(&[&1]) |> Enum.sort() ==
             [0, 0, 3, 22]
    end

    test "uniq_by/2" do
      assert @flow |> Flow.uniq_by(&rem(&1, 2)) |> Enum.sort() == [1, 2, 3, 4, 10]
    end

    test "uniq_by/2 after reduce/3" do
      assert @flow
             |> Flow.reduce(fn -> [] end, &[&1 | &2])
             |> Flow.map_state(&Enum.sort/1)
             |> Flow.uniq_by(&rem(&1, 2))
             |> Enum.sort() == [1, 2, 3, 4, 10]
    end

    test "keeps ordering" do
      flow =
        @flow
        |> Flow.filter(&rem(&1, 2) == 0)
        |> Flow.map(fn(x) -> x + 1 end)
        |> Flow.map(fn(x) -> x * 2 end)
      assert Enum.sort(flow) == [6, 10, 14, 18, 22]
    end

    test "keeps ordering after reduce" do
      flow =
        @flow
        |> Flow.reduce(fn -> [] end, &[&1 | &2])
        |> Flow.filter(&rem(&1, 2) == 0)
        |> Flow.map(fn(x) -> x + 1 end)
        |> Flow.map(fn(x) -> x * 2 end)
      assert Enum.sort(flow) == [6, 10, 14, 18, 22]
    end

    test "keeps ordering after reduce + map_state" do
      flow =
        @flow
        |> Flow.reduce(fn -> [] end, &[&1 | &2])
        |> Flow.filter(&rem(&1, 2) == 0)
        |> Flow.map(fn(x) -> x + 1 end)
        |> Flow.map(fn(x) -> x * 2 end)
        |> Flow.map_state(&{&2, Enum.sort(&1)})
        |> Flow.map_state(&[&1])
      assert Enum.sort(flow) == [{{0, 4}, [6, 14, 18]},
                                 {{1, 4}, [22]},
                                 {{2, 4}, []},
                                 {{3, 4}, [10]}]
    end

    test "start_link/2" do
      parent = self()

      {:ok, _} =
        @flow
        |> Flow.filter(&rem(&1, 2) == 0)
        |> Flow.each(&send(parent, &1))
        |> Flow.start_link()

      assert_receive 2
      assert_receive 4
      assert_receive 6
      refute_received 1
    end

    test "into_stages/3" do
      {:ok, forwarder} = GenStage.start_link(Forwarder, self())

      {:ok, _} =
        @flow
        |> Flow.filter(&rem(&1, 2) == 0)
        |> Flow.into_stages([forwarder])

      assert_receive {:consumed, [2]}
      assert_receive {:consumed, [4]}
      assert_receive {:consumed, [6]}
      assert_receive {:consumed, '\b'}
      assert_receive {:consumed, '\n'}
    end
  end

  describe "stages-unpartioned-stream" do
    @tag report: [:counter]

    setup do
      {:ok, pid} = GenStage.start_link(Counter, 0)
      {:ok, counter: pid}
    end

    test "only sources", %{counter: pid} do
      assert Flow.from_stage(pid, stages: 1)
             |> Enum.take(5)
             |> Enum.sort() == [0, 1, 2, 3, 4]
    end

    test "each/2", %{counter: pid} do
      parent = self()
      assert Flow.from_stage(pid, stages: 1)
             |> Flow.each(&send(parent, &1))
             |> Enum.take(5)
             |> Enum.sort() == [0, 1, 2, 3, 4]
      assert_received 1
      assert_received 2
      assert_received 3
    end

    test "filter/2", %{counter: pid} do
      assert Flow.from_stage(pid, stages: 1)
             |> Flow.filter(&rem(&1, 2) == 0)
             |> Enum.take(5)
             |> Enum.sort() == [0, 2, 4, 6, 8]
    end

    test "filter_map/3", %{counter: pid} do
      assert Flow.from_stage(pid, stages: 1)
             |> Flow.filter_map(&rem(&1, 2) == 0, & &1 * 2)
             |> Enum.take(5)
             |> Enum.sort() == [0, 4, 8, 12, 16]
    end

    test "flat_map/2", %{counter: pid} do
      assert Flow.from_stage(pid, stages: 1)
             |> Flow.flat_map(&[&1, &1])
             |> Enum.take(5)
             |> Enum.sort() == [0, 0, 1, 1, 2]
    end

    test "map/2", %{counter: pid} do
      assert Flow.from_stage(pid, stages: 1)
             |> Flow.map(& &1 * 2)
             |> Enum.take(5)
             |> Enum.sort() == [0, 2, 4, 6, 8]
    end

    test "reject/2", %{counter: pid} do
      assert Flow.from_stage(pid, stages: 1)
             |> Flow.reject(&rem(&1, 2) == 0)
             |> Enum.take(5)
             |> Enum.sort() ==
             [1, 3, 5, 7, 9]
    end

    test "keeps ordering", %{counter: pid} do
      assert Flow.from_stage(pid, stages: 1)
             |> Flow.filter(&rem(&1, 2) == 0)
             |> Flow.map(fn(x) -> x + 1 end)
             |> Flow.map(fn(x) -> x * 2 end)
             |> Enum.take(5)
             |> Enum.sort() == [2, 6, 10, 14, 18]
    end
  end

  describe "partition/2" do
    test "allows custom partitioning" do
      assert Flow.from_enumerables([[1, 2, 3], [4, 5, 6], 7..10])
             |> Flow.partition(hash: fn x -> {x, 0} end, stages: 4)
             |> Flow.reduce(fn -> [] end, &[&1 | &2])
             |> Flow.map_state(&[Enum.sort(&1)])
             |> Enum.sort() == [[], [], [], [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]]
    end

    test "allows element based partitioning" do
      assert Flow.from_enumerables([[{1, 1}, {2, 2}, {3, 3}], [{1, 4}, {2, 5}, {3, 6}]])
             |> Flow.partition(hash: {:elem, 0}, stages: 2)
             |> Flow.reduce(fn -> [] end, &[&1 | &2])
             |> Flow.map_state(fn acc -> [acc |> Enum.map(&elem(&1, 1)) |> Enum.sort()] end)
             |> Enum.sort() == [[1, 2, 4, 5], [3, 6]]
    end

    test "allows key based partitioning" do
      assert Flow.from_enumerables([[%{key: 1, value: 1}, %{key: 2, value: 2}, %{key: 3, value: 3}],
                                    [%{key: 1, value: 4}, %{key: 2, value: 5}, %{key: 3, value: 6}]])
             |> Flow.partition(hash: {:key, :key}, stages: 2)
             |> Flow.reduce(fn -> [] end, &[&1 | &2])
             |> Flow.map_state(fn acc -> [acc |> Enum.map(& &1.value) |> Enum.sort()] end)
             |> Enum.sort() == [[1, 2, 4, 5], [3, 6]]
    end

    test "allows custom windowding" do
      window =
        Flow.Window.fixed(1, :second, fn
          x when x <= 50 -> 0
          x when x <= 100 -> 1_000
        end)

      assert Flow.from_enumerable(1..100)
             |> Flow.partition(window: window, stages: 4)
             |> Flow.reduce(fn -> [] end, &[&1 | &2])
             |> Flow.map_state(&[Enum.sum(&1)])
             |> Enum.sort() == [173, 361, 364, 377, 797, 865, 895, 1218]
    end
  end

  describe "departition/2" do
    test "joins partitioned data" do
      assert Flow.from_enumerable(1..10)
             |> Flow.partition(stages: 4)
             |> Flow.reduce(fn -> 0 end, &+/2)
             |> Flow.departition(fn -> [] end, &[&1 | &2], &Enum.sort/1)
             |> Enum.at(0) == [7, 10, 16, 22]
    end

    test "joins partitioned data with window info" do
      assert Flow.from_enumerable(1..10)
             |> Flow.partition(stages: 4)
             |> Flow.reduce(fn -> 0 end, &+/2)
             |> Flow.departition(fn -> [] end, &[&1 | &2], &{&2, Enum.sort(&1)})
             |> Enum.at(0) == {:global, [7, 10, 16, 22]}
    end

    test "joins partitioned data with triggers" do
      assert Flow.from_enumerable(1..10)
             |> Flow.partition(stages: 4, window: Flow.Window.global |> Flow.Window.trigger_every(2, :keep))
             |> Flow.reduce(fn -> 0 end, &+/2)
             |> Flow.departition(fn -> [] end, &[&1 | &2], &Enum.sort/1)
             |> Enum.at(0) ==  [6, 7, 7, 8, 10, 16, 22, 22]

      assert Flow.from_enumerable(1..10)
             |> Flow.partition(stages: 4, window: Flow.Window.global |> Flow.Window.trigger_every(2, :reset))
             |> Flow.reduce(fn -> 0 end, &+/2)
             |> Flow.departition(fn -> [] end, &[&1 | &2], &Enum.sort/1)
             |> Enum.at(0) == [0, 0, 6, 7, 8, 8, 10, 16]
    end

    test "joins partitioned data with map operations" do
      assert Flow.from_enumerable(1..10)
             |> Flow.partition(stages: 4)
             |> Flow.reduce(fn -> 0 end, &+/2)
             |> Flow.departition(fn -> [] end, &[&1 | &2], & &1)
             |> Flow.map(&Enum.sort/1)
             |> Enum.at(0) == [7, 10, 16, 22]
    end

    test "joins partitioned data with reduce operations" do
      assert Flow.from_enumerable(1..10)
             |> Flow.partition(stages: 4, window: Flow.Window.global |> Flow.Window.trigger_every(2, :reset))
             |> Flow.reduce(fn -> 0 end, &+/2)
             |> Flow.departition(fn -> [] end, &[&1 | &2], &Enum.sort/1)
             |> Flow.reduce(fn -> 0 end, & Enum.sum(&1) + &2)
             |> Flow.emit(:state)
             |> Enum.at(0) == 55
    end
  end

  defp merged_flows(options) do
    flow1 =
      Stream.take_every(1..100, 2)
      |> Flow.from_enumerable()
      |> Flow.map(& &1 * 2)

    flow2 =
      Stream.take_every(2..100, 2)
      |> Flow.from_enumerable()
      |> Flow.map(& &1 * 2)

    Flow.merge([flow1, flow2], options)
  end

  describe "merge/2" do
    test "merges different flows together" do
      assert merged_flows(stages: 4, min_demand: 5)
             |> Flow.reduce(fn -> 0 end, & &1 + &2)
             |> Flow.emit(:state)
             |> Enum.sum() == 10100
    end

    test "allows custom partitioning" do
      assert merged_flows(stages: 4, min_demand: 5, hash: fn x -> {x, 0} end)
             |> Flow.reduce(fn -> [] end, &[&1 | &2])
             |> Flow.map_state(&[Enum.sum(&1)])
             |> Enum.sort() == [0, 0, 0, 10100]
    end

    test "allows custom windowding" do
      window =
        Flow.Window.fixed(1, :second, fn
          x when x <= 100 -> 0
          x when x <= 200 -> 1_000
        end)

      assert merged_flows(window: window, stages: 4, min_demand: 5)
             |> Flow.reduce(fn -> [] end, &[&1 | &2])
             |> Flow.map_state(&[Enum.sum(&1)])
             |> Enum.sort() == [594, 596, 654, 706, 1248, 1964, 2066, 2272]
    end
  end

  describe "bounded_join/7" do
    test "inner joins two matching flows" do
      assert Flow.bounded_join(:inner,
                               Flow.from_enumerable([0, 1, 2, 3]),
                               Flow.from_enumerable([4, 5, 6, 7, 8]),
                               & &1, & &1 - 3, &{&1, &2})
             |> Enum.sort() == [{1, 4}, {2, 5}, {3, 6}]
    end

    test "inner joins two unmatching flows" do
      assert Flow.bounded_join(:inner,
                               Flow.from_enumerable([0, 1, 2, 3]),
                               Flow.from_enumerable([4, 5, 6, 7, 8]),
                               & &1, & &1, &{&1, &2})
             |> Enum.sort() == []
    end

    test "left joins two matching flows" do
      assert Flow.bounded_join(:left_outer,
                               Flow.from_enumerable([0, 1, 2, 3]),
                               Flow.from_enumerable([4, 5, 6, 7, 8]),
                               & &1, & &1 - 3, &{&1, &2})
             |> Enum.sort() == [{0, nil}, {1, 4}, {2, 5}, {3, 6}]
    end

    test "left joins two unmatching flows" do
      assert Flow.bounded_join(:left_outer,
                               Flow.from_enumerable([0, 1, 2, 3]),
                               Flow.from_enumerable([4, 5, 6, 7, 8]),
                               & &1, & &1, &{&1, &2})
             |> Enum.sort() == [{0, nil}, {1, nil}, {2, nil}, {3, nil}]
    end

    test "right joins two matching flows" do
      assert Flow.bounded_join(:right_outer,
                               Flow.from_enumerable([0, 1, 2, 3]),
                               Flow.from_enumerable([4, 5, 6, 7, 8]),
                               & &1, & &1 - 3, &{&1, &2})
             |> Enum.sort() == [{1, 4}, {2, 5}, {3, 6}, {nil, 7}, {nil, 8}]
    end

    test "right joins two unmatching flows" do
      assert Flow.bounded_join(:right_outer,
                               Flow.from_enumerable([0, 1, 2, 3]),
                               Flow.from_enumerable([4, 5, 6, 7, 8]),
                               & &1, & &1, &{&1, &2})
             |> Enum.sort() == [{nil, 4}, {nil, 5}, {nil, 6}, {nil, 7}, {nil, 8}]
    end

    test "outer joins two matching flows" do
      assert Flow.bounded_join(:full_outer,
                               Flow.from_enumerable([0, 1, 2, 3]),
                               Flow.from_enumerable([4, 5, 6, 7, 8]),
                               & &1, & &1 - 3, &{&1, &2})
             |> Enum.sort() == [{0, nil}, {1, 4}, {2, 5}, {3, 6}, {nil, 7}, {nil, 8}]
    end

    test "outer joins two unmatching flows" do
      assert Flow.bounded_join(:full_outer,
                               Flow.from_enumerable([0, 1, 2, 3]),
                               Flow.from_enumerable([4, 5, 6, 7, 8]),
                               & &1, & &1, &{&1, &2})
             |> Enum.sort() == [{0, nil}, {1, nil}, {2, nil}, {3, nil},
                                {nil, 4}, {nil, 5}, {nil, 6}, {nil, 7}, {nil, 8}]
    end

    test "joins two flows followed by mapper operation" do
      assert Flow.bounded_join(:inner,
                               Flow.from_enumerable([0, 1, 2, 3]),
                               Flow.from_enumerable([4, 5, 6]),
                               & &1, & &1 - 3, &{&1, &2})
             |> Flow.map(fn {k, v} -> k + v end)
             |> Enum.sort() == [5, 7, 9]
    end

    test "joins two flows followed by reduce" do
      assert Flow.bounded_join(:inner,
                               Flow.from_enumerable([0, 1, 2, 3]),
                               Flow.from_enumerable([4, 5, 6]),
                               & &1, & &1 - 3, &{&1, &2}, stages: 2)
             |> Flow.reduce(fn -> 0 end, fn {k, v}, acc -> k + v + acc end)
             |> Flow.emit(:state)
             |> Enum.sort() == [9, 12]
    end

    test "joins mapper and reducer flows" do
      assert Flow.bounded_join(:inner,
                               Flow.from_enumerable(0..9) |> Flow.partition(),
                               Flow.from_enumerable(0..9) |> Flow.map(& &1 + 10),
                               & &1, & &1 - 10, &{&1, &2}, stages: 2)
             |> Flow.reduce(fn -> 0 end, fn {k, v}, acc -> k + v + acc end)
             |> Flow.emit(:state)
             |> Enum.sort() == [44, 146]
    end

    test "outer joins two flows with windows" do
      window = Flow.Window.fixed(10, :millisecond, & &1) |> Flow.Window.trigger_every(2)
      # Notice how 9 and 12 do not form a pair for being in different windows.
      assert Flow.window_join(:full_outer,
                              Flow.from_enumerable([0, 1, 2, 3, 9, 10, 11]),
                              Flow.from_enumerable([4, 5, 6, 7, 8, 12, 13]),
                              window, & &1, & &1 - 3, &{&1, &2})
             |> Enum.sort() == [{0, nil}, {1, 4}, {2, 5}, {3, 6}, {9, nil},
                                {10, 13}, {11, nil}, {nil, 7}, {nil, 8}, {nil, 12}]
    end
  end
end
