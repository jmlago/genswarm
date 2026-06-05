defmodule Mix.Tasks.Swarm.Msg do
  @shortdoc "Send a message between agents"

  @moduledoc """
  Sends a message from one agent to another in a swarm.

  The message is routed according to the swarm's topology. If the
  route is not allowed, an error is returned.

  ## Usage

      mix swarm msg <swarm_name> <from_agent> <to_agent> <message>

  ## Examples

      mix swarm msg my-swarm researcher coder "Can you review this code?"
      mix swarm msg my-swarm coder researcher "I need more context"
  """

  use Mix.Task

  alias Genswarm.CLI.Output
  alias Genswarm.Routing.Router

  @impl Mix.Task
  def run([swarm_name, from, to, message]) do
    # Router needs full app
    {:ok, _} = Application.ensure_all_started(:genswarm)

    from_atom = String.to_atom(from)
    to_atom = String.to_atom(to)

    # Validate route before sending (route is now async)
    case Router.get_connections(swarm_name, from_atom) do
      {:ok, connections} ->
        if to_atom in connections do
          Output.info("Sending message: #{from} -> #{to}")
          Router.route(swarm_name, from_atom, to_atom, message)
          Output.success("Message sent")
        else
          Output.error("Invalid route: #{from} cannot send to #{to}")
          Output.newline()
          show_valid_routes(swarm_name, from_atom)
          System.halt(1)
        end

      {:error, :unknown_swarm} ->
        Output.error("Swarm not found: #{swarm_name}")
        System.halt(1)

      {:error, reason} ->
        Output.error("Failed to validate route: #{inspect(reason)}")
        System.halt(1)
    end
  end

  def run([swarm_name, from, to]) do
    Output.error("Missing message content")
    Output.info("Usage: mix swarm msg #{swarm_name} #{from} #{to} \"message\"")
  end

  def run(_) do
    Output.error("Usage: mix swarm msg <swarm> <from> <to> <message>")
    Output.newline()
    Output.puts("Example:")
    Output.puts("  mix swarm msg my-swarm researcher coder \"Review this code\"")
  end

  defp show_valid_routes(swarm_name, from) do
    case Router.get_connections(swarm_name, from) do
      {:ok, connections} when connections != [] ->
        Output.info("Valid targets for #{from}:")
        Output.list(Enum.map(connections, &to_string/1))

      {:ok, []} ->
        Output.warning("#{from} has no outgoing connections in the topology")

      {:error, _} ->
        :ok
    end
  end
end
