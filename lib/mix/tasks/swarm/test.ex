defmodule Mix.Tasks.Swarm.Test do
  @moduledoc """
  Runs end-to-end tests on example swarm configurations.

  ## Usage

      mix swarm.test                        # Validate + run all examples
      mix swarm.test --validate-only        # Only validate configs, don't run
      mix swarm.test --example tic-tac-toe  # Test a specific example
      mix swarm.test --timeout 60000        # Custom timeout per swarm (ms)
      mix swarm.test --steps 3              # Steps for .sim examples
      mix swarm.test --logs-dir /tmp/logs   # Custom logs directory

  ## What it does

  1. Discovers all swarm configs (.exs) and sim files (.sim) in examples/
  2. Validates each one
  3. Runs each (starts swarm, waits for completion or timeout)
  4. Captures full logs per example
  5. Reports pass/fail for each

  ## Logs

  Full run output saved to .test-logs/:

      .test-logs/
      ├── tic_tac_toe_swarm.log
      ├── party_swarm.log
      └── summary.log

  Exit code is 0 if all pass, 1 if any fail.
  """

  use Mix.Task

  require Logger

  @shortdoc "Run e2e tests on example swarm configurations"

  @impl true
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          validate_only: :boolean,
          example: :string,
          timeout: :integer,
          steps: :integer,
          quiet: :boolean,
          logs_dir: :string,
          mock: :string
        ]
      )

    Application.ensure_all_started(:genswarm)

    # Mock mode: set env var so subzeroclaw uses canned responses instead of API
    if opts[:mock] do
      mock_path = Path.expand(opts[:mock])
      System.put_env("SUBZEROCLAW_MOCK_SCRIPT", mock_path)
      Mix.shell().info("Mock mode: #{mock_path}")
    end

    examples_dir = Path.join(File.cwd!(), "examples")
    timeout = opts[:timeout] || 60_000
    steps = opts[:steps] || 3
    validate_only = opts[:validate_only] || false
    quiet = opts[:quiet] || false
    logs_dir = Path.expand(opts[:logs_dir] || ".test-logs")

    unless validate_only do
      File.mkdir_p!(logs_dir)
      Mix.shell().info("Logs directory: #{logs_dir}")
    end

    # Discover configs
    config_files =
      examples_dir
      |> Path.join("**/*.exs")
      |> Path.wildcard()
      |> Enum.sort()
      |> maybe_filter_example(opts[:example])

    sim_files =
      examples_dir
      |> Path.join("**/*.sim")
      |> Path.wildcard()
      |> Enum.sort()
      |> maybe_filter_example(opts[:example])

    all_files = config_files ++ sim_files

    if all_files == [] do
      Mix.shell().error("No config files found in #{examples_dir}")
      System.halt(1)
    end

    Mix.shell().info("\n=== Genswarm E2E Tests ===")
    Mix.shell().info("Found #{length(all_files)} configurations\n")

    results =
      Enum.map(all_files, fn file ->
        relative = Path.relative_to(file, File.cwd!())
        test_config(relative, file, validate_only, quiet, timeout, steps, logs_dir)
      end)

    # Summary
    passed = Enum.count(results, fn {s, _} -> s == :pass end)
    failed = Enum.count(results, fn {s, _} -> s == :fail end)
    skipped = Enum.count(results, fn {s, _} -> s == :skip end)

    summary = "#{passed} passed, #{failed} failed, #{skipped} skipped"

    Mix.shell().info("\n=== Results ===")
    Mix.shell().info(summary)

    unless validate_only do
      summary_lines = Enum.map(results, fn {status, name} ->
        icon = case status do
          :pass -> "✓"
          :fail -> "✗"
          :skip -> "⊘"
        end
        "#{icon} #{name}"
      end)

      summary_path = Path.join(logs_dir, "summary.log")
      File.write!(summary_path, Enum.join(["=== #{summary} ===\n" | summary_lines], "\n"))
      Mix.shell().info("Summary: #{summary_path}")
    end

    if failed > 0, do: System.halt(1)
  end

  defp test_config(relative, file, validate_only, quiet, timeout, steps, logs_dir) do
    cond do
      String.ends_with?(file, ".exs") ->
        test_exs_config(relative, file, validate_only, quiet, timeout, logs_dir)

      String.ends_with?(file, ".sim") ->
        test_sim_config(relative, file, validate_only, quiet, timeout, steps, logs_dir)

      true ->
        {:skip, relative}
    end
  end

  # Test .exs swarm configs
  defp test_exs_config(relative, file, validate_only, quiet, timeout, logs_dir) do
    try do
      {config, _} = Code.eval_file(file)

      cond do
        is_map(config) and Map.has_key?(config, :name) ->
          agents = Map.get(config, :agents, [])
          objects = Map.get(config, :objects, [])

          if validate_only do
            unless quiet do
              Mix.shell().info("  \e[32m✓\e[0m #{relative} (#{length(agents)} agents, #{length(objects)} objects)")
            end
            {:pass, relative}
          else
            run_swarm_config(relative, config, timeout, quiet, logs_dir)
          end

        is_map(config) ->
          unless quiet, do: Mix.shell().info("  \e[32m✓\e[0m #{relative} (valid map config)")
          {:pass, relative}

        true ->
          unless quiet, do: Mix.shell().info("  \e[33m⊘\e[0m #{relative} (not a swarm config)")
          {:skip, relative}
      end
    rescue
      e ->
        Mix.shell().error("  \e[31m✗\e[0m #{relative} (#{Exception.message(e)})")
        {:fail, relative}
    end
  end

  # Test .sim files via SubzeroSim
  defp test_sim_config(relative, file, validate_only, quiet, timeout, steps, logs_dir) do
    if Code.ensure_loaded?(SubzeroSim.Loader) do
      case apply(SubzeroSim.Loader, :load, [file]) do
        {:ok, spec} ->
          case apply(SubzeroSim.Validator, :validate, [spec]) do
            :ok ->
              if validate_only do
                unless quiet, do: Mix.shell().info("  \e[32m✓\e[0m #{relative} (valid sim)")
                {:pass, relative}
              else
                run_sim(relative, spec, timeout, steps, quiet, logs_dir)
              end

            {:error, errors} ->
              Mix.shell().error("  \e[31m✗\e[0m #{relative} (#{inspect(errors)})")
              {:fail, relative}
          end

        {:error, reason} ->
          Mix.shell().error("  \e[31m✗\e[0m #{relative} (#{inspect(reason)})")
          {:fail, relative}
      end
    else
      unless quiet, do: Mix.shell().info("  \e[33m⊘\e[0m #{relative} (SubzeroSim not available)")
      {:skip, relative}
    end
  end

  # Run a swarm config with timeout and log capture
  defp run_swarm_config(relative, config, timeout, quiet, logs_dir) do
    name = config[:name] || "unknown"
    log_name = name |> to_string() |> String.replace(~r/[^a-zA-Z0-9_-]/, "_")
    log_path = Path.join(logs_dir, "#{log_name}.log")

    agents = Map.get(config, :agents, [])
    objects = Map.get(config, :objects, [])
    topology = Map.get(config, :topology, [])

    task =
      Task.async(fn ->
        try do
          case Genswarm.SwarmManager.start_from_config(config) do
            {:ok, swarm_name} ->
              Process.sleep(timeout)
              Genswarm.SwarmManager.stop(swarm_name)
              {:ok, %{status: :ran, swarm_name: swarm_name}}

            {:error, reason} ->
              {:error, reason}
          end
        rescue
          e -> {:error, Exception.message(e)}
        end
      end)

    result = Task.yield(task, timeout + 10_000) || Task.shutdown(task)

    log_content = [
      "=== #{relative} ===",
      "Swarm: #{name}",
      "Agents: #{length(agents)} — #{inspect(Enum.map(agents, & &1[:name]))}",
      "Objects: #{length(objects)} — #{inspect(Enum.map(objects, & &1[:name]))}",
      "Topology: #{inspect(topology)}",
      "Timeout: #{timeout}ms",
      "",
      case result do
        {:ok, {:ok, info}} -> "Status: #{inspect(info)}"
        {:ok, {:error, reason}} -> "ERROR: #{inspect(reason)}"
        nil -> "TIMEOUT (killed after #{timeout + 10_000}ms)"
      end
    ] |> Enum.join("\n")

    File.write!(log_path, log_content)

    case result do
      {:ok, {:ok, _info}} ->
        unless quiet, do: Mix.shell().info("  \e[32m✓\e[0m #{relative} (ran #{timeout}ms) → #{log_path}")
        {:pass, relative}

      {:ok, {:error, reason}} ->
        Mix.shell().error("  \e[31m✗\e[0m #{relative} (#{inspect(reason)}) → #{log_path}")
        {:fail, relative}

      nil ->
        Mix.shell().error("  \e[31m✗\e[0m #{relative} (timeout) → #{log_path}")
        {:fail, relative}
    end
  end

  # Run a .sim file via SubzeroSim runner
  defp run_sim(relative, spec, timeout, steps, quiet, logs_dir) do
    log_name = spec.name |> String.replace(~r/[^a-zA-Z0-9_-]/, "_")
    log_path = Path.join(logs_dir, "#{log_name}.log")

    task =
      Task.async(fn ->
        try do
          apply(SubzeroSim.Runner, :run_and_collect, [spec, [steps: steps, timeout: timeout]])
        rescue
          e -> {:error, Exception.message(e)}
        end
      end)

    result = Task.yield(task, timeout + 5_000) || Task.shutdown(task)

    log_content = [
      "=== #{relative} ===",
      "Sim: #{spec.name}",
      "Steps: #{steps}, Timeout: #{timeout}ms",
      "Agents: #{inspect(Enum.map(spec.roles, & &1.name))}",
      "",
      case result do
        {:ok, {:ok, info}} ->
          [
            "Status: #{Map.get(info, :status, :unknown)}",
            "Final step: #{Map.get(info, :final_step, "?")}",
            "Halt reason: #{Map.get(info, :halt_reason, "none")}",
            "Metrics: #{inspect(Map.get(info, :metrics, %{}))}"
          ]
        {:ok, {:error, reason}} -> ["ERROR: #{inspect(reason)}"]
        nil -> ["TIMEOUT"]
      end
    ] |> List.flatten() |> Enum.join("\n")

    File.write!(log_path, log_content)

    case result do
      {:ok, {:ok, info}} ->
        status = Map.get(info, :status, :unknown)
        unless quiet, do: Mix.shell().info("  \e[32m✓\e[0m #{relative} (#{status}) → #{log_path}")
        {:pass, relative}

      {:ok, {:error, reason}} ->
        Mix.shell().error("  \e[31m✗\e[0m #{relative} (#{inspect(reason)}) → #{log_path}")
        {:fail, relative}

      nil ->
        Mix.shell().error("  \e[31m✗\e[0m #{relative} (timeout) → #{log_path}")
        {:fail, relative}
    end
  end

  defp maybe_filter_example(files, nil), do: files

  defp maybe_filter_example(files, name) do
    Enum.filter(files, fn path ->
      String.contains?(path, "/#{name}/")
    end)
  end
end
