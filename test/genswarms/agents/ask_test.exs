defmodule Genswarms.Agents.AskTest do
  use ExUnit.Case, async: true

  alias Genswarms.Agents.Ask

  describe "valid_correlation_id?/1" do
    test "accepts the swarm-msg shape" do
      assert Ask.valid_correlation_id?("ask_1234_1717270000000000000")
      assert Ask.valid_correlation_id?("a-B.0_z")
    end

    test "rejects a trailing newline (the ^$ vs \\A\\z regex trap)" do
      refute Ask.valid_correlation_id?("abc\n")
      refute Ask.valid_correlation_id?("abc\nx")
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

    test "error-null/false is SUCCESS (JSON-RPC shape), not a failure" do
      env = Ask.envelope(~s({"result":42,"error":null}), "cn1", 1)
      assert env.ok == true
      assert env.error == nil

      env = Ask.envelope(%{"data" => 1, "error" => false}, "cn2", 1)
      assert env.ok == true
    end

    test "a native handler's map reply gets the same semantics as encoded JSON" do
      env = Ask.envelope(%{"campaigns" => [1]}, "c5m", 2)
      assert env.ok == true
      assert env.result == %{"campaigns" => [1]}

      err = Ask.envelope(%{error: %{code: "nope", type: "permanent"}}, "c5e", 2)
      assert err.ok == false
      assert err.error == %{code: "nope", message: "nope", type: "permanent"}
    end

    test "envelope is JSON-encodable (the contract with swarm-msg)" do
      assert {:ok, _} = Jason.encode(Ask.envelope(~s({"a":1}), "c6", 2))
      assert {:ok, _} = Jason.encode(Ask.error_envelope("c7", "route_denied", "no edge"))
    end

    test "non-stringable error fields are inspected, never raised on (review round 3 finding 5)" do
      # to_string/1 on a map/list raises Protocol.UndefinedError — and this
      # normalization runs OUTSIDE the object server's handler rescue, so a
      # reply like {"error":{"code":{"upstream":...}}} crashed the
      # ObjectServer and stranded the asker.
      env = Ask.envelope(~s({"error":{"code":{"upstream":502},"message":["a","b"]}}), "cns1", 1)

      assert env.ok == false
      assert env.error.code == inspect(%{"upstream" => 502})
      assert env.error.message == inspect(["a", "b"])
      assert env.error.type == "unknown"
      assert {:ok, _} = Jason.encode(env)

      # message defaults to the (non-stringable) code when absent
      env2 = Ask.envelope(%{"error" => %{"code" => %{"k" => 1}}}, "cns2", 1)
      assert env2.error.message == inspect(%{"k" => 1})

      # binaries still pass through untouched; atoms keep their to_string form
      env3 = Ask.envelope(%{"error" => %{"code" => "nope", "type" => :permanent}}, "cns3", 1)
      assert env3.error.code == "nope"
      assert env3.error.type == "permanent"
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
