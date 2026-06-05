defmodule GenswarmsWeb.ConnCase do
  @moduledoc "ExUnit case for controller/endpoint tests (in-process dispatch)."
  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint GenswarmsWeb.Endpoint
      import Plug.Conn
      import Phoenix.ConnTest
    end
  end

  setup _tags do
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
