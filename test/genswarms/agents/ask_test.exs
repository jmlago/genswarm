defmodule Genswarms.Agents.AskTest do
  use ExUnit.Case, async: true

  alias Genswarms.Agents.Ask

  describe "valid_correlation_id?/1" do
    test "accepts the swarm-msg shape" do
      assert Ask.valid_correlation_id?("ask_1234_1717270000000000000")
      assert Ask.valid_correlation_id?("a-B.0_z")
    end

    test "rejects path traversal and shell metacharacters" do
      refute Ask.valid_correlation_id?("../etc/passwd")
      refute Ask.valid_correlation_id?("a/b")
      refute Ask.valid_correlation_id?("a\\b")
      refute Ask.valid_correlation_id?("..")
      refute Ask.valid_correlation_id?(".")
      refute Ask.valid_correlation_id?("a b")
      refute Ask.valid_correlation_id?("a;b")
      refute Ask.valid_correlation_id?("")
      refute Ask.valid_correlation_id?(nil)
      refute Ask.valid_correlation_id?(String.duplicate("x", 129))
    end
  end

  describe "envelope/3" do
    test "wraps a JSON object reply as ok" do
      env = Ask.envelope(~s({"campaigns":[1,2]}), "c1", 12)

      assert env.ok == true
      assert env.result == %{"campaigns" => [1, 2]}
      assert env.error == nil
      assert env.timeout == false
      assert env.correlation_id == "c1"
      assert env.duration_ms == 12
    end

    test "lifts a top-level string error into ok:false" do
      env = Ask.envelope(~s({"error":"not_allowed"}), "c2", 5)

      assert env.ok == false
      assert env.error == %{code: "not_allowed", message: "not_allowed", type: "unknown"}
      # the full reply is preserved so nothing the object said is lost
      assert env.result == %{"error" => "not_allowed"}
    end

    test "passes through an object-provided error map with type" do
      env =
        Ask.envelope(
          ~s({"error":{"code":"http_404","message":"page not found","type":"permanent"}}),
          "c3",
          7
        )

      assert env.ok == false
      assert env.error == %{code: "http_404", message: "page not found", type: "permanent"}
    end

    test "a nil response (handler did not reply) is an ok envelope with nil result" do
      env = Ask.envelope(nil, "c4", 3)
      assert env.ok == true
      assert env.result == nil
    end

    test "a non-JSON reply is passed through as raw text" do
      env = Ask.envelope("plain text", "c5", 1)
      assert env.ok == true
      assert env.result == %{"raw" => "plain text"}
    end

    test "envelope is JSON-encodable (the contract with swarm-msg)" do
      assert {:ok, _} = Jason.encode(Ask.envelope(~s({"a":1}), "c6", 2))
      assert {:ok, _} = Jason.encode(Ask.error_envelope("c7", "route_denied", "no edge"))
    end
  end

  describe "error_envelope/4" do
    test "builds a typed permanent failure by default" do
      env = Ask.error_envelope("c8", "target_not_found", "no such object")

      assert env.ok == false
      assert env.error.code == "target_not_found"
      assert env.error.type == "permanent"
      assert env.timeout == false
    end
  end

  describe "write_reply/3" do
    setup do
      workspace = Path.join(System.tmp_dir!(), "ask_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(workspace)
      on_exit(fn -> File.rm_rf!(workspace) end)
      {:ok, workspace: workspace}
    end

    test "writes the envelope atomically to .inbox/replies/<corr>.json", %{workspace: ws} do
      env = Ask.envelope(~s({"x":1}), "ok_1", 4)
      assert :ok = Ask.write_reply(ws, "ok_1", env)

      path = Path.join([ws, ".inbox", "replies", "ok_1.json"])
      assert {:ok, content} = File.read(path)
      assert Jason.decode!(content)["result"] == %{"x" => 1}
      # no tmp residue
      assert File.ls!(Path.dirname(path)) == ["ok_1.json"]
    end

    test "refuses an invalid correlation id (no path traversal write)", %{workspace: ws} do
      env = Ask.envelope(nil, "x", 0)
      assert {:error, :invalid_correlation_id} = Ask.write_reply(ws, "../escape", env)
      refute File.exists?(Path.join(ws, "../escape.json"))
    end

    test "refuses a missing workspace" do
      assert {:error, :no_workspace} = Ask.write_reply(nil, "ok_2", Ask.envelope(nil, "ok_2", 0))
      assert {:error, :no_workspace} = Ask.write_reply("", "ok_2", Ask.envelope(nil, "ok_2", 0))
    end
  end
end
