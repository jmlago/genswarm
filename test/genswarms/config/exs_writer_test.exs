defmodule Genswarms.Config.ExsWriterTest do
  @moduledoc """
  Snapshots (`ExsWriter.to_exs_source/1`) must not persist secrets in cleartext
  (audit finding 30, CWE-312), while preserving non-secret config.
  """
  use ExUnit.Case, async: true

  alias Genswarms.Config.{ExsWriter, SwarmConfig}

  defp source(agents) do
    ExsWriter.to_exs_source(%SwarmConfig{
      name: "s",
      agents: agents,
      objects: [],
      topology: []
    })
  end

  test "redacts secret-looking keys in agent :config but keeps non-secret keys" do
    src =
      source([
        %{
          name: :worker,
          backend: :bwrap,
          config: %{
            api_key: "sk-live-SECRET",
            extra_env: %{"DB_PASSWORD" => "pw-SECRET", "LOG_LEVEL" => "info"},
            population_size: 10
          }
        }
      ])

    # secrets gone
    refute src =~ "sk-live-SECRET"
    refute src =~ "pw-SECRET"
    assert src =~ "[REDACTED]"

    # non-secret config preserved
    assert src =~ "population_size"
    assert src =~ "LOG_LEVEL"
    assert src =~ "info"
  end

  test "redacts secrets nested inside backend opts tuples" do
    src = source([%{name: :w, backend: {:docker, "img", %{api_key: "sk-SECRET2"}}}])

    refute src =~ "sk-SECRET2"
    assert src =~ "[REDACTED]"
    # non-secret backend data preserved
    assert src =~ "docker"
    assert src =~ "img"
  end

  test "catches assorted secret key spellings (token, password, secret, credential)" do
    src =
      source([
        %{
          name: :w,
          backend: :mock,
          config: %{
            "API_TOKEN" => "tok-SECRET",
            "service_secret" => "sec-SECRET",
            "user_password" => "pw-SECRET",
            "aws_credential" => "cred-SECRET"
          }
        }
      ])

    for leaked <- ["tok-SECRET", "sec-SECRET", "pw-SECRET", "cred-SECRET"] do
      refute src =~ leaked, "leaked #{leaked}"
    end
  end

  test "output remains valid, parseable Elixir" do
    src =
      source([%{name: :worker, backend: :bwrap, config: %{api_key: "sk-SECRET", n: 1}}])

    assert {:ok, _ast} = Code.string_to_quoted(src)
  end

  test "agents without secrets are unaffected" do
    src = source([%{name: :plain, backend: :local, config: %{population_size: 5}}])
    refute src =~ "[REDACTED]"
    assert src =~ "population_size"
  end

  test "key_path is NOT redacted (it is a filename, not a secret)" do
    # Round-trip must preserve key_path so restored SSH agents still work.
    src = source([%{name: :sshagent, backend: :local, config: %{key_path: "~/.ssh/id_ed25519"}}])
    assert src =~ "~/.ssh/id_ed25519"
    refute src =~ "[REDACTED]"
  end

  test "api_key alongside key_path: only the secret is redacted" do
    src =
      source([
        %{name: :a, backend: :local, config: %{api_key: "sk-SECRET", key_path: "~/.ssh/id"}}
      ])

    refute src =~ "sk-SECRET"
    assert src =~ "~/.ssh/id"
    assert src =~ "[REDACTED]"
  end
end
