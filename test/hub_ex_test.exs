defmodule EchoTest do

  use ExUnit.Case
  
  Hub.start

  test "hub is running and sorta works" do
    assert(Hub.dump())
  end

  test "hub handles basic updates and sequence numbers" do
    {{initial_lock, initial_seq}, _} = Hub.fetch
    result = Hub.update [ "kg7ga", "rig", "kw" ], [ "afgain": 32 ], []
    assert {:changes, new_ver, [kg7ga: [rig: [kw: [afgain: 32]]]] } = result
    {new_lock, new_seq} = new_ver
    assert is_integer(new_seq)
    assert new_seq > initial_seq
    assert new_lock == initial_lock
  end

  test "Hub handles basic update and differencing correctly" do
    test_data = [ basic_key: "yes", another_key: "no", with: 3 ]
    test_rootkey = :nemo_temp_tests
    test_subkey = :some_sub_path
    test_path = [ test_rootkey, test_subkey ]
    expected_changes = [{test_rootkey, [{test_subkey, test_data}]}]
    {{initial_lock, initial_seq}, _} = Hub.fetch
    { resp_type, new_ver, resp_changes } = Hub.update test_path, test_data
    assert resp_type == :changes
    {new_lock, new_seq} = new_ver
    assert new_seq == (initial_seq + 1)
    assert new_lock == initial_lock
    assert resp_changes == expected_changes

    # now test difference engine!   write some new data where only one
    # field has changed, and then make sure only that field is reported
    # as changed.

    test_data2 = [ basic_key: "yes", another_key: "maybe", with: 3 ]
    test_changes2 = [ another_key: "maybe" ]
    expected_changes2 = [{test_rootkey, [{test_subkey, test_changes2}]}]
    { resp_type, resp_ver2, resp_changes } = Hub.update test_path, test_data2
    assert resp_type == :changes
    {resp_lock2, resp_seq2} = resp_ver2
    assert resp_seq2 == new_seq + 1
    assert resp_lock2 == initial_lock
    assert resp_changes == expected_changes2

 	  # now test case where we dont' make any changes, we should get back
 	  # :nochanges with an empty changelist

    { resp_type, resp_ver3, resp_changes } = Hub.update test_path, test_data2
    assert resp_type == :nochanges
    assert {initial_lock, (new_seq + 1)} == resp_ver3
    assert resp_seq2 == new_seq + 1
    assert resp_lock2 == initial_lock
    assert resp_changes == []

  end
end
