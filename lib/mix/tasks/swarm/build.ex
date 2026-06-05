defmodule Mix.Tasks.Swarm.Build do
  @shortdoc "Build Docker images via nix"

  @moduledoc """
  Builds Docker images for swarm agents using Nix.

  ## Usage

      mix swarm build [image]
      mix swarm build --all

  ## Available Images

      base        Base agent image with common tools
      python      Python development image
      node        Node.js development image
      elixir      Elixir development image

  ## Options

      --all       Build all images
      --push      Push to registry after building
      --tag TAG   Custom tag (default: latest)
      --no-cache  Build without cache

  ## Examples

      mix swarm build base              # Build base image
      mix swarm build --all             # Build all images
      mix swarm build base --push       # Build and push
      mix swarm build base --tag v1.0   # Custom tag
  """

  use Mix.Task

  alias Genswarm.CLI.Output

  @available_images ["base", "python", "node", "elixir"]

  @impl Mix.Task
  def run(args) do
    {opts, rest, _} =
      OptionParser.parse(args,
        strict: [
          all: :boolean,
          push: :boolean,
          tag: :string,
          no_cache: :boolean,
          help: :boolean
        ],
        aliases: [a: :all, p: :push, t: :tag, h: :help]
      )

    if opts[:help] do
      Mix.shell().info(@moduledoc)
    else
      cond do
        opts[:all] ->
          build_all(opts)

        length(rest) > 0 ->
          Enum.each(rest, &build_image(&1, opts))

        true ->
          Output.error("Specify an image to build or use --all")
          Output.newline()
          Output.info("Available images:")
          Output.list(@available_images)
      end
    end
  end

  defp build_all(opts) do
    Output.header("Building all images")

    Enum.each(@available_images, fn image ->
      build_image(image, opts)
    end)
  end

  defp build_image(image, opts) do
    unless image in @available_images do
      Output.error("Unknown image: #{image}")
      Output.info("Available: #{Enum.join(@available_images, ", ")}")
      return_or_halt(opts[:all])
    end

    tag = opts[:tag] || "latest"
    image_name = "subzeroclaw-#{image}:#{tag}"

    Output.info("Building #{image_name}...")

    # Check for nix
    unless command_exists?("nix") do
      Output.error("Nix is not installed")
      Output.info("Install from: https://nixos.org/download.html")
      System.halt(1)
    end

    # Check for nix flake
    flake_path = find_flake_path()

    unless flake_path do
      # Fall back to Docker build
      build_with_docker(image, image_name, opts)
    else
      build_with_nix(flake_path, image, image_name, opts)
    end
  end

  defp build_with_nix(flake_path, image, image_name, opts) do
    nix_attr = "packages.x86_64-linux.docker-#{image}"

    args = ["build", flake_path, "--attr", nix_attr]

    args =
      if opts[:no_cache] do
        args ++ ["--rebuild"]
      else
        args
      end

    Output.dim("Running: nix #{Enum.join(args, " ")}")

    case System.cmd("nix", args, stderr_to_stdout: true, into: IO.stream(:stdio, :line)) do
      {_, 0} ->
        Output.success("Built #{image_name}")

        if opts[:push] do
          push_image(image_name, opts)
        end

      {output, code} ->
        Output.error("Build failed (exit code #{code})")
        Output.puts(output)
        return_or_halt(opts[:all])
    end
  end

  defp build_with_docker(image, image_name, opts) do
    dockerfile = "docker/Dockerfile.#{image}"

    unless File.exists?(dockerfile) do
      # Try generic dockerfile
      dockerfile = "docker/Dockerfile.agent"

      unless File.exists?(dockerfile) do
        Output.error("Dockerfile not found: docker/Dockerfile.#{image}")
        return_or_halt(opts[:all])
      end
    end

    args = ["build", "-t", image_name, "-f", dockerfile, "."]

    args =
      if opts[:no_cache] do
        ["--no-cache" | args]
      else
        args
      end

    Output.dim("Running: docker #{Enum.join(args, " ")}")

    case System.cmd("docker", args, stderr_to_stdout: true, into: IO.stream(:stdio, :line)) do
      {_, 0} ->
        Output.success("Built #{image_name}")

        if opts[:push] do
          push_image(image_name, opts)
        end

      {output, code} ->
        Output.error("Build failed (exit code #{code})")
        Output.puts(output)
        return_or_halt(opts[:all])
    end
  end

  defp push_image(image_name, _opts) do
    registry = System.get_env("DOCKER_REGISTRY")

    if is_nil(registry) do
      Output.warning("DOCKER_REGISTRY not set, skipping push")
    else
      full_name = "#{registry}/#{image_name}"

      Output.info("Pushing #{full_name}...")

      # Tag for registry
      case System.cmd("docker", ["tag", image_name, full_name]) do
        {_, 0} ->
          # Push
          case System.cmd("docker", ["push", full_name], stderr_to_stdout: true) do
            {_, 0} ->
              Output.success("Pushed #{full_name}")

            {output, _} ->
              Output.error("Failed to push: #{output}")
          end

        {output, _} ->
          Output.error("Failed to tag: #{output}")
      end
    end
  end

  defp find_flake_path do
    # Look for flake.nix in current directory or parent
    cond do
      File.exists?("flake.nix") -> "."
      File.exists?("../flake.nix") -> ".."
      true -> nil
    end
  end

  defp command_exists?(cmd) do
    case System.cmd("which", [cmd], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  end

  defp return_or_halt(true), do: :ok
  defp return_or_halt(_), do: System.halt(1)
end
