defmodule Genswarms.Config.NetConfig do
  @moduledoc """
  Network binding helpers for the HTTP endpoint.

  The production endpoint binds to a configurable address that defaults to
  loopback, so a fresh deployment is not exposed on every interface by accident.
  Operators that need wider exposure (e.g. inside a container behind a proxy) set
  `GENSWARMS_HTTP_IP` explicitly (`0.0.0.0`, `::`, a specific address).
  """

  @loopback {127, 0, 0, 1}

  @doc """
  Parses a bind address string into an `:inet` address tuple.

  Returns loopback (`127.0.0.1`) for `nil`, blank, or unparseable input, so the
  default and the failure mode are both the safe, closed option.
  """
  @spec bind_ip(String.t() | nil) :: :inet.ip_address()
  def bind_ip(value)
  def bind_ip(nil), do: @loopback
  def bind_ip(""), do: @loopback

  def bind_ip(str) when is_binary(str) do
    case str |> String.trim() |> String.to_charlist() |> :inet.parse_address() do
      {:ok, addr} -> addr
      {:error, _} -> @loopback
    end
  end
end
