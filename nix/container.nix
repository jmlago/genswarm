# NixOS-based container image builder for Genswarm agents
#
# This creates Docker images with NixOS that include only the
# tools specified for each agent. Images are minimal and reproducible.
#
# Usage:
#   nix build .#agentContainer-base
#   nix build .#agentContainer-web
#   nix build .#agentContainer-code
#
# Or build custom:
#   nix build .#lib.x86_64-linux.mkAgentContainer --argstr name myagent --arg presets '["base" "web"]'

{ pkgs, toolPresets }:

{
  # Build a minimal NixOS-based container with specified tools
  mkAgentContainer = {
    name,
    tools ? [],
    presets ? [ "base" ],
    extraPackages ? [],
    subzeroclawBinary ? null,  # Path to subzeroclaw binary to include
  }:
  let
    # Resolve presets to actual packages
    presetPackages = builtins.concatLists (
      map (preset: toolPresets.${preset} or []) presets
    );

    # Resolve individual tools
    toolPackages = map (tool: toolPresets.tools.${tool} or pkgs.${tool}) tools;

    # All packages for this agent
    allPackages = presetPackages ++ toolPackages ++ extraPackages ++ [
      pkgs.bashInteractive
      pkgs.coreutils
      pkgs.cacert  # SSL certificates
      # Nix package manager for runtime installation (nix-shell -p ...)
      pkgs.nix
    ];

    # Create the wrapper script
    wrapperScript = pkgs.writeShellScriptBin "szc-wrapper" ''
      #!/usr/bin/env bash
      # Protocol wrapper for subzeroclaw
      AGENT_NAME="$1"
      SZC_PATH="''${2:-subzeroclaw}"
      SKILLS_DIR="$3"

      export SUBZEROCLAW_AGENT_NAME="$AGENT_NAME"
      [ -n "$SKILLS_DIR" ] && export SUBZEROCLAW_SKILLS="$SKILLS_DIR"

      # Simple wrapper - read JSON, translate, run subzeroclaw
      exec "$SZC_PATH"
    '';

    # swarm-msg CLI for inter-agent messaging
    swarmMsg = pkgs.writeShellScriptBin "swarm-msg" (builtins.readFile ../swarm-msg);

  in pkgs.dockerTools.buildLayeredImage {
    name = "szc-agent-${name}";
    tag = "latest";

    contents = [
      wrapperScript
      swarmMsg
    ] ++ allPackages;

    # Create necessary directories and nix config
    fakeRootCommands = ''
      mkdir -p ./tmp ./etc/nix
      chmod 1777 ./tmp
      echo "build-users-group =" > ./etc/nix/nix.conf
      echo "experimental-features = nix-command flakes" >> ./etc/nix/nix.conf
    '';

    config = {
      Cmd = [ "${pkgs.bashInteractive}/bin/bash" ];
      Env = [
        "PATH=/bin:${pkgs.lib.makeBinPath allPackages}"
        "AGENT_NAME=${name}"
        "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
        "NIX_SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
        "NIX_PATH=nixpkgs=${pkgs.path}"
        "NIX_CONF_DIR=/etc/nix"
        "TMPDIR=/tmp"
      ];
      WorkingDir = "/workspace";
      Volumes = {
        "/workspace" = {};
        "/skills" = {};
        "/tmp" = {};
      };
    };

    # Layered image for better caching
    maxLayers = 100;
  };

  # Pre-defined agent images for common use cases
  images = {
    # Minimal base agent
    base = {
      name = "base";
      presets = [ "base" ];
    };

    # Web research agent
    web = {
      name = "web";
      presets = [ "base" "web" ];
    };

    # Code/development agent
    code = {
      name = "code";
      presets = [ "base" "code" ];
    };

    # Data processing agent
    data = {
      name = "data";
      presets = [ "base" "data" ];
    };

    # Full-featured agent
    full = {
      name = "full";
      presets = [ "base" "web" "code" "data" "python" "node" ];
    };

    # Python-focused agent
    python = {
      name = "python";
      presets = [ "base" "python" "data" ];
    };

    # Node.js-focused agent
    node = {
      name = "node";
      presets = [ "base" "node" "web" ];
    };

    # DevOps/Cloud agent
    devops = {
      name = "devops";
      presets = [ "base" "code" "containers" "cloud" ];
    };
  };
}
