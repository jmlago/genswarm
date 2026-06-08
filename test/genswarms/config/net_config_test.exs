defmodule Genswarms.Config.NetConfigTest do
  use ExUnit.Case, async: true

  alias Genswarms.Config.NetConfig

  describe "bind_ip/1" do
    test "defaults to loopback for nil and blank input" do
      assert NetConfig.bind_ip(nil) == {127, 0, 0, 1}
      assert NetConfig.bind_ip("") == {127, 0, 0, 1}
    end

    test "parses an explicit IPv4 address" do
      assert NetConfig.bind_ip("0.0.0.0") == {0, 0, 0, 0}
      assert NetConfig.bind_ip("127.0.0.1") == {127, 0, 0, 1}
      assert NetConfig.bind_ip("192.168.1.5") == {192, 168, 1, 5}
    end

    test "parses an explicit IPv6 address" do
      assert NetConfig.bind_ip("::") == {0, 0, 0, 0, 0, 0, 0, 0}
      assert NetConfig.bind_ip("::1") == {0, 0, 0, 0, 0, 0, 0, 1}
    end

    test "trims surrounding whitespace" do
      assert NetConfig.bind_ip("  0.0.0.0  ") == {0, 0, 0, 0}
    end

    test "falls back to loopback (safe) on unparseable input" do
      assert NetConfig.bind_ip("not-an-ip") == {127, 0, 0, 1}
      assert NetConfig.bind_ip("999.999.999.999") == {127, 0, 0, 1}
      assert NetConfig.bind_ip("0.0.0.0:4000") == {127, 0, 0, 1}
    end
  end
end
