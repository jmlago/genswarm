defmodule GenswarmsWeb.CorsTest do
  # async: false — these mutate the :genswarms/:cors_origins application env.
  use ExUnit.Case, async: false

  alias GenswarmsWeb.Cors

  setup do
    original = Application.get_env(:genswarms, :cors_origins)
    on_exit(fn -> restore(:genswarms, :cors_origins, original) end)
    :ok
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, val), do: Application.put_env(app, key, val)

  describe "allowed?/2 against the default (localhost) allowlist" do
    setup do
      {:ok, default: Cors.origins_setting()}
    end

    test "allows localhost / 127.0.0.1 / ::1 on any scheme and port", %{default: d} do
      for origin <- [
            "http://localhost",
            "http://localhost:3000",
            "https://localhost:4000",
            "http://127.0.0.1:5173",
            "https://127.0.0.1",
            "http://[::1]:4000"
          ] do
        assert Cors.allowed?(origin, d), "expected #{origin} to be allowed"
      end
    end

    test "denies non-local origins", %{default: d} do
      for origin <- [
            "https://evil.com",
            "http://example.com",
            "https://api.example.com"
          ] do
        refute Cors.allowed?(origin, d), "expected #{origin} to be denied"
      end
    end

    test "denies look-alikes that try to smuggle localhost (anchored regex)", %{default: d} do
      for origin <- [
            "http://localhost.evil.com",
            "https://notlocalhost",
            "http://localhost:3000.evil.com",
            "http://127.0.0.1.evil.com",
            "http://evil.com/localhost"
          ] do
        refute Cors.allowed?(origin, d), "expected #{origin} to be denied"
      end
    end
  end

  describe "allowed?/2 with explicit settings" do
    test ":all allows anything" do
      assert Cors.allowed?("https://anything.example", :all)
      assert Cors.allowed?("http://localhost:1", :all)
    end

    test "string allowlist requires an exact match" do
      list = ["https://app.example.com", "http://localhost:3000"]
      assert Cors.allowed?("https://app.example.com", list)
      assert Cors.allowed?("http://localhost:3000", list)
      refute Cors.allowed?("https://app.example.com:443", list)
      refute Cors.allowed?("https://evil.example.com", list)
      refute Cors.allowed?("https://app.example.com/", list)
    end
  end

  describe "origins_setting/0 from application env" do
    test "unset → localhost default (a list of matchers)" do
      Application.delete_env(:genswarms, :cors_origins)
      assert is_list(Cors.origins_setting())
      refute Cors.allowed?("https://evil.com", Cors.origins_setting())
    end

    test "blank string → localhost default" do
      Application.put_env(:genswarms, :cors_origins, "")
      refute Cors.allowed?("https://evil.com", Cors.origins_setting())
      assert Cors.allowed?("http://localhost:3000", Cors.origins_setting())
    end

    test "\"*\" → :all" do
      Application.put_env(:genswarms, :cors_origins, "*")
      assert Cors.origins_setting() == :all
    end

    test "comma-separated list is parsed and trimmed" do
      Application.put_env(:genswarms, :cors_origins, " https://a.com , https://b.com ")
      assert Cors.origins_setting() == ["https://a.com", "https://b.com"]
    end
  end

  describe "allowed_origin?/2 (the Corsica MFA callback) reads runtime config" do
    test "defaults to localhost-only when unset" do
      Application.delete_env(:genswarms, :cors_origins)
      assert Cors.allowed_origin?(%Plug.Conn{}, "http://localhost:4000")
      refute Cors.allowed_origin?(%Plug.Conn{}, "https://evil.com")
    end

    test "honours an explicit allowlist" do
      Application.put_env(:genswarms, :cors_origins, "https://dashboard.example.com")
      assert Cors.allowed_origin?(%Plug.Conn{}, "https://dashboard.example.com")
      refute Cors.allowed_origin?(%Plug.Conn{}, "https://evil.com")
      refute Cors.allowed_origin?(%Plug.Conn{}, "http://localhost:4000")
    end

    test "honours \"*\"" do
      Application.put_env(:genswarms, :cors_origins, "*")
      assert Cors.allowed_origin?(%Plug.Conn{}, "https://anything.example")
    end
  end
end
