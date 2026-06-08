defmodule Genswarms.AuthTest do
  # not async: configured_token/0 reads global application env
  use ExUnit.Case, async: false

  alias Genswarms.Auth

  @token "s3cret-token-value"
  @remote {203, 0, 113, 7}
  @loop4 {127, 0, 0, 1}
  @loop4_other {127, 5, 9, 11}
  @loop6 {0, 0, 0, 0, 0, 0, 0, 1}
  @loop6_mapped {0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 0x0001}

  describe "authorize/3 — token configured" do
    test "accepts the exact matching bearer token (regardless of source IP)" do
      assert Auth.authorize(@token, @token, @remote) == :ok
      assert Auth.authorize(@token, @token, @loop4) == :ok
      assert Auth.authorize(@token, @token, nil) == :ok
    end

    test "rejects a wrong token" do
      assert Auth.authorize(@token, "nope", @loop4) == {:error, :unauthorized}
    end

    test "rejects a missing (nil) token even from loopback" do
      assert Auth.authorize(@token, nil, @loop4) == {:error, :unauthorized}
    end

    test "rejects an empty presented token" do
      assert Auth.authorize(@token, "", @loop4) == {:error, :unauthorized}
    end

    test "rejects a token that is a prefix/suffix of the real one (constant-time exact match)" do
      assert Auth.authorize(@token, String.slice(@token, 0..-2//1), @remote) ==
               {:error, :unauthorized}

      assert Auth.authorize(@token, @token <> "x", @remote) == {:error, :unauthorized}
    end
  end

  describe "authorize/3 — no token configured" do
    for {desc, cfg} <- [{"nil", nil}, {"empty string", ""}] do
      test "allows loopback callers (config #{desc})" do
        cfg = unquote(cfg)
        assert Auth.authorize(cfg, nil, @loop4) == :ok
        assert Auth.authorize(cfg, nil, @loop4_other) == :ok
        assert Auth.authorize(cfg, nil, @loop6) == :ok
        assert Auth.authorize(cfg, nil, @loop6_mapped) == :ok
      end

      test "refuses remote callers (config #{desc})" do
        cfg = unquote(cfg)
        assert Auth.authorize(cfg, nil, @remote) == {:error, :token_required}
        assert Auth.authorize(cfg, "anything", @remote) == {:error, :token_required}
      end

      test "refuses callers with unknown IP (nil) (config #{desc})" do
        assert Auth.authorize(unquote(cfg), nil, nil) == {:error, :token_required}
      end
    end
  end

  describe "loopback?/1" do
    test "true for IPv4 loopback range and IPv6 loopback" do
      assert Auth.loopback?(@loop4)
      assert Auth.loopback?(@loop4_other)
      assert Auth.loopback?(@loop6)
      assert Auth.loopback?(@loop6_mapped)
    end

    test "false for public/private non-loopback and nil" do
      refute Auth.loopback?(@remote)
      refute Auth.loopback?({10, 0, 0, 5})
      refute Auth.loopback?({192, 168, 1, 1})
      refute Auth.loopback?(nil)
    end
  end

  describe "configured_token/0" do
    setup do
      prev = Application.get_env(:genswarms, :api_token)
      on_exit(fn -> restore(:api_token, prev) end)
      :ok
    end

    test "returns the token when set" do
      Application.put_env(:genswarms, :api_token, "abc")
      assert Auth.configured_token() == "abc"
    end

    test "returns nil when unset" do
      Application.delete_env(:genswarms, :api_token)
      assert Auth.configured_token() == nil
    end

    test "treats an empty token as unset" do
      Application.put_env(:genswarms, :api_token, "")
      assert Auth.configured_token() == nil
    end
  end

  defp restore(key, nil), do: Application.delete_env(:genswarms, key)
  defp restore(key, val), do: Application.put_env(:genswarms, key, val)
end
