defmodule GenswarmsWeb.ConfigControllerTest do
  # not async: toggles global :api_token and dispatches through the router
  use ExUnit.Case, async: false

  import Plug.Test

  setup do
    prev = Application.get_env(:genswarms, :api_token)
    # no token + loopback => auth allows the request through to the controller
    Application.delete_env(:genswarms, :api_token)

    on_exit(fn ->
      case prev do
        nil -> Application.delete_env(:genswarms, :api_token)
        v -> Application.put_env(:genswarms, :api_token, v)
      end
    end)

    :ok
  end

  defp post_validate(params) do
    %{conn(:post, "/api/config/validate", params) | remote_ip: {127, 0, 0, 1}}
    |> GenswarmsWeb.Router.call(GenswarmsWeb.Router.init([]))
  end

  test "rejects .exs request content with 400 and never executes it (RCE)" do
    marker = Path.join(System.tmp_dir!(), "cfg_ctrl_rce_#{System.unique_integer([:positive])}")
    File.rm(marker)
    content = ~s|File.write!(#{inspect(marker)}, "pwned"); %{name: "n", agents: []}|

    conn = post_validate(%{"content" => content, "format" => "exs"})

    assert conn.status == 400
    assert %{"valid" => false} = Jason.decode!(conn.resp_body)
    refute File.exists?(marker), "RCE: .exs request content was executed by the controller"
  end

  test "accepts a valid JSON content config" do
    content = ~s|{"name":"n","agents":[{"name":"a","backend":"local"}],"topology":[]}|
    conn = post_validate(%{"content" => content, "format" => "json"})

    assert conn.status == 200
    assert %{"valid" => true} = Jason.decode!(conn.resp_body)
  end
end
