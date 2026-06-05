defmodule TicTacToe.Objects.Game do
  @moduledoc """
  Tic-tac-toe game object. Validates moves and manages turns between two agents.
  """

  @behaviour Genswarm.Objects.ObjectHandler

  alias Genswarm.Objects.ObjectServer

  # Swarm name for logging - set during init
  @swarm_name "tic-tac-toe"

  @impl true
  def init(_config) do
    board = [
      [".", ".", "."],
      [".", ".", "."],
      [".", ".", "."]
    ]

    state = %{board: board, turn: :player_x, game_over: false, winner: nil, move_count: 0}

    ObjectServer.log(:info, @swarm_name, :game, "Game initialized, sending first turn to player_x", %{
      first_player: :player_x
    })

    # Send initial your_turn message to player_x to start the game
    initial_message = encode(:your_turn, %{board: board})
    {:ok, state, {:send, :player_x, initial_message}}
  end

  @impl true
  def interface do
    %{
      move: %{
        input: ~s({"board": [["X",".","."],[".",".","."],[".",".","."]]}),
        output: "Validates move, sends board to next player or announces winner"
      }
    }
  end

  @impl true
  def handle_message(from, content, state) do
    cond do
      state.game_over ->
        ObjectServer.log(:warning, @swarm_name, :game, "Move rejected: game already over", %{
          from: from,
          winner: state.winner
        })
        {:reply, encode(:error, "Game over. #{winner_msg(state.winner)}"), state}

      from != state.turn ->
        ObjectServer.log(:warning, @swarm_name, :game, "Move rejected: not #{from}'s turn", %{
          from: from,
          expected: state.turn
        })
        {:reply, encode(:error, "Not your turn, waiting for #{state.turn}"), state}

      true ->
        process_move(from, content, state)
    end
  end

  defp process_move(from, content, state) do
    with {:ok, %{"board" => new_board}} <- Jason.decode(content),
         :ok <- validate_board(new_board),
         piece = if(from == :player_x, do: "X", else: "O"),
         :ok <- validate_move(state.board, new_board, piece) do
      next = if from == :player_x, do: :player_o, else: :player_x
      move_num = state.move_count + 1
      new_state = %{state | board: new_board, turn: next, move_count: move_num}

      ObjectServer.log(:info, @swarm_name, :game, "Move #{move_num}: #{from} placed #{piece}", %{
        player: from,
        piece: piece,
        move_number: move_num,
        board: format_board(new_board)
      })

      case check_result(new_board) do
        {:win, p} ->
          winner = if p == "X", do: :player_x, else: :player_o
          final = %{new_state | game_over: true, winner: winner}
          ObjectServer.log(:info, @swarm_name, :game, "Game over: #{winner} wins!", %{
            winner: winner,
            total_moves: move_num,
            final_board: format_board(new_board)
          })
          {:broadcast, encode(:game_over, %{board: new_board, winner: winner}), final}

        :draw ->
          final = %{new_state | game_over: true, winner: :draw}
          ObjectServer.log(:info, @swarm_name, :game, "Game over: Draw!", %{
            result: :draw,
            total_moves: move_num,
            final_board: format_board(new_board)
          })
          {:broadcast, encode(:game_over, %{board: new_board, winner: "draw"}), final}

        :continue ->
          {:send, next, encode(:your_turn, %{board: new_board}), new_state}
      end
    else
      {:ok, _} ->
        ObjectServer.log(:warning, @swarm_name, :game, "Invalid move format from #{from}", %{from: from})
        {:reply, encode(:error, "Send {\"board\": [[...],[...],[...]]}"), state}
      {:error, msg} when is_binary(msg) ->
        ObjectServer.log(:warning, @swarm_name, :game, "Invalid move from #{from}: #{msg}", %{
          from: from,
          reason: msg
        })
        {:reply, encode(:error, msg), state}
      {:error, _} ->
        ObjectServer.log(:warning, @swarm_name, :game, "Invalid JSON from #{from}", %{from: from})
        {:reply, encode(:error, "Invalid JSON"), state}
    end
  end

  defp format_board(board) do
    board
    |> Enum.map(&Enum.join(&1, " "))
    |> Enum.join(" | ")
  end

  defp validate_board(b) do
    valid = [".", "X", "O"]

    if length(b) == 3 and Enum.all?(b, &(length(&1) == 3)) and
         Enum.all?(b, fn r -> Enum.all?(r, &(&1 in valid)) end) do
      :ok
    else
      {:error, "Board must be 3x3 with only '.', 'X', 'O'"}
    end
  end

  defp validate_move(old, new, piece) do
    changes =
      for {or_, nr, r} <- Enum.zip([old, new, 0..2]),
          {oc, nc, c} <- Enum.zip([or_, nr, 0..2]),
          oc != nc,
          do: {r, c, oc, nc}

    case changes do
      [{_, _, ".", ^piece}] -> :ok
      [{_, _, ".", other}] -> {:error, "Wrong piece. You are #{piece}, placed #{other}"}
      [{_, _, _, _}] -> {:error, "Cannot overwrite existing piece"}
      [] -> {:error, "No move detected"}
      _ -> {:error, "Only one move allowed per turn"}
    end
  end

  defp check_result(b) do
    lines = [
      [at(b, 0, 0), at(b, 0, 1), at(b, 0, 2)],
      [at(b, 1, 0), at(b, 1, 1), at(b, 1, 2)],
      [at(b, 2, 0), at(b, 2, 1), at(b, 2, 2)],
      [at(b, 0, 0), at(b, 1, 0), at(b, 2, 0)],
      [at(b, 0, 1), at(b, 1, 1), at(b, 2, 1)],
      [at(b, 0, 2), at(b, 1, 2), at(b, 2, 2)],
      [at(b, 0, 0), at(b, 1, 1), at(b, 2, 2)],
      [at(b, 0, 2), at(b, 1, 1), at(b, 2, 0)]
    ]

    winner = Enum.find_value(lines, fn l ->
      cond do
        Enum.all?(l, &(&1 == "X")) -> "X"
        Enum.all?(l, &(&1 == "O")) -> "O"
        true -> nil
      end
    end)

    cond do
      winner -> {:win, winner}
      Enum.all?(b, fn r -> Enum.all?(r, &(&1 != ".")) end) -> :draw
      true -> :continue
    end
  end

  defp at(b, r, c), do: Enum.at(Enum.at(b, r), c)

  defp winner_msg(:draw), do: "It's a draw!"
  defp winner_msg(w), do: "#{w} wins!"

  defp encode(status, data) when is_map(data), do: Jason.encode!(%{status: status, data: data})
  defp encode(status, msg), do: Jason.encode!(%{status: status, message: msg})
end
