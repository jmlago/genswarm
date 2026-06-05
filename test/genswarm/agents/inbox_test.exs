defmodule Genswarm.Agents.InboxTest do
  use ExUnit.Case, async: true

  alias Genswarm.Agents.Inbox

  describe "new/1" do
    test "creates empty inbox" do
      inbox = Inbox.new()

      assert Inbox.empty?(inbox)
      assert Inbox.size(inbox) == 0
    end

    test "accepts max_size option" do
      inbox = Inbox.new(max_size: 5)

      assert inbox.max_size == 5
    end
  end

  describe "push/2" do
    test "adds message to inbox" do
      inbox = Inbox.new()
      {:ok, inbox} = Inbox.push(inbox, %{content: "hello"})

      assert Inbox.size(inbox) == 1
      refute Inbox.empty?(inbox)
    end

    test "returns error when inbox is full" do
      inbox = Inbox.new(max_size: 2)
      {:ok, inbox} = Inbox.push(inbox, %{content: "1"})
      {:ok, inbox} = Inbox.push(inbox, %{content: "2"})

      assert {:error, :inbox_full} = Inbox.push(inbox, %{content: "3"})
    end
  end

  describe "pop/1" do
    test "removes and returns oldest message" do
      inbox = Inbox.new()
      {:ok, inbox} = Inbox.push(inbox, %{content: "first"})
      {:ok, inbox} = Inbox.push(inbox, %{content: "second"})

      {:ok, msg, inbox} = Inbox.pop(inbox)
      assert msg.content == "first"
      assert Inbox.size(inbox) == 1
    end

    test "returns empty for empty inbox" do
      inbox = Inbox.new()
      assert {:empty, ^inbox} = Inbox.pop(inbox)
    end
  end

  describe "peek/1" do
    test "returns oldest message without removing" do
      inbox = Inbox.new()
      {:ok, inbox} = Inbox.push(inbox, %{content: "first"})

      assert {:ok, msg} = Inbox.peek(inbox)
      assert msg.content == "first"
      assert Inbox.size(inbox) == 1
    end

    test "returns empty for empty inbox" do
      inbox = Inbox.new()
      assert :empty = Inbox.peek(inbox)
    end
  end

  describe "clear/1" do
    test "removes all messages" do
      inbox = Inbox.new()
      {:ok, inbox} = Inbox.push(inbox, %{content: "1"})
      {:ok, inbox} = Inbox.push(inbox, %{content: "2"})

      inbox = Inbox.clear(inbox)
      assert Inbox.empty?(inbox)
    end
  end

  describe "to_list/1" do
    test "returns messages in FIFO order" do
      inbox = Inbox.new()
      {:ok, inbox} = Inbox.push(inbox, %{content: "first"})
      {:ok, inbox} = Inbox.push(inbox, %{content: "second"})
      {:ok, inbox} = Inbox.push(inbox, %{content: "third"})

      list = Inbox.to_list(inbox)
      assert [%{content: "first"}, %{content: "second"}, %{content: "third"}] = list
    end
  end

  describe "drain/1" do
    test "returns all messages and clears inbox" do
      inbox = Inbox.new()
      {:ok, inbox} = Inbox.push(inbox, %{content: "1"})
      {:ok, inbox} = Inbox.push(inbox, %{content: "2"})

      {messages, new_inbox} = Inbox.drain(inbox)

      assert length(messages) == 2
      assert Inbox.empty?(new_inbox)
    end
  end
end
