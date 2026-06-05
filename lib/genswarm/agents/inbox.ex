defmodule Genswarm.Agents.Inbox do
  @moduledoc """
  FIFO queue-based inbox for agent messages.

  Uses Erlang's `:queue` module for efficient enqueueing and dequeueing.
  """

  defstruct queue: :queue.new(), size: 0, max_size: 1000

  @type message :: map()
  @type t :: %__MODULE__{
          queue: :queue.queue(message()),
          size: non_neg_integer(),
          max_size: non_neg_integer()
        }

  @doc """
  Creates a new empty inbox.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      queue: :queue.new(),
      size: 0,
      max_size: Keyword.get(opts, :max_size, 1000)
    }
  end

  @doc """
  Adds a message to the inbox.

  Returns `{:ok, inbox}` or `{:error, :inbox_full}` if max size reached.
  """
  @spec push(t(), message()) :: {:ok, t()} | {:error, :inbox_full}
  def push(%__MODULE__{size: size, max_size: max} = _inbox, _message) when size >= max do
    {:error, :inbox_full}
  end

  def push(%__MODULE__{queue: queue, size: size} = inbox, message) do
    new_queue = :queue.in(message, queue)
    {:ok, %{inbox | queue: new_queue, size: size + 1}}
  end

  @doc """
  Removes and returns the oldest message from the inbox.

  Returns `{:ok, message, inbox}` or `{:empty, inbox}` if inbox is empty.
  """
  @spec pop(t()) :: {:ok, message(), t()} | {:empty, t()}
  def pop(%__MODULE__{size: 0} = inbox), do: {:empty, inbox}

  def pop(%__MODULE__{queue: queue, size: size} = inbox) do
    case :queue.out(queue) do
      {{:value, message}, new_queue} ->
        {:ok, message, %{inbox | queue: new_queue, size: size - 1}}

      {:empty, _} ->
        {:empty, inbox}
    end
  end

  @doc """
  Peeks at the oldest message without removing it.
  """
  @spec peek(t()) :: {:ok, message()} | :empty
  def peek(%__MODULE__{queue: queue}) do
    case :queue.peek(queue) do
      {:value, message} -> {:ok, message}
      :empty -> :empty
    end
  end

  @doc """
  Returns the number of messages in the inbox.
  """
  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{size: size}), do: size

  @doc """
  Checks if the inbox is empty.
  """
  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{size: 0}), do: true
  def empty?(_), do: false

  @doc """
  Clears all messages from the inbox.
  """
  @spec clear(t()) :: t()
  def clear(%__MODULE__{} = inbox) do
    %{inbox | queue: :queue.new(), size: 0}
  end

  @doc """
  Converts the inbox to a list (oldest first).
  """
  @spec to_list(t()) :: [message()]
  def to_list(%__MODULE__{queue: queue}) do
    :queue.to_list(queue)
  end

  @doc """
  Drains all messages from the inbox, returning them as a list.
  """
  @spec drain(t()) :: {[message()], t()}
  def drain(%__MODULE__{} = inbox) do
    messages = to_list(inbox)
    {messages, clear(inbox)}
  end
end
