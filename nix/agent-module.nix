# NixOS module for Genswarm agent nodes
#
# This module configures a NixOS machine to run as a swarm agent.
# Deploy with Colmena to remote machines.
#
# Usage in flake.nix colmena config:
#   agent-node = {
#     imports = [ ./nix/agent-module.nix ];
#     swarm.agent = {
#       enable = true;
#       name = "researcher";
#       presets = [ "base" "web" ];
#       tools = [ "ripgrep" "fd" ];
#       skills = [ "web.md" ];
#       orchestratorHost = "192.168.1.10";
#     };
#   };

{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.swarm.agent;
  toolPresets = import ./tool-presets.nix { inherit pkgs; };

  # Resolve all packages from presets and tools
  presetPackages = builtins.concatLists (
    map (preset: toolPresets.${preset} or []) cfg.presets
  );

  toolPackages = map (tool:
    if builtins.hasAttr tool toolPresets.tools
    then toolPresets.tools.${tool}
    else pkgs.${tool}
  ) cfg.tools;

  allPackages = presetPackages ++ toolPackages;

in {
  options.swarm.agent = {
    enable = mkEnableOption "Genswarm agent";

    name = mkOption {
      type = types.str;
      description = "Agent name identifier";
    };

    presets = mkOption {
      type = types.listOf types.str;
      default = [ "base" ];
      description = "Tool presets to include (base, web, code, data, etc.)";
    };

    tools = mkOption {
      type = types.listOf types.str;
      default = [];
      description = "Individual tools to include";
    };

    skills = mkOption {
      type = types.listOf types.str;
      default = [];
      description = "Skill files to deploy";
    };

    skillsDir = mkOption {
      type = types.path;
      default = /var/lib/subzeroclaw/skills;
      description = "Directory for skill files";
    };

    workDir = mkOption {
      type = types.path;
      default = /var/lib/subzeroclaw/workspace;
      description = "Working directory for agent";
    };

    orchestratorHost = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Orchestrator host for callbacks (optional)";
    };

    user = mkOption {
      type = types.str;
      default = "subzeroclaw";
      description = "User to run agent as";
    };

    group = mkOption {
      type = types.str;
      default = "subzeroclaw";
      description = "Group to run agent as";
    };

    apiKeyFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "Path to file containing API key (use with sops-nix)";
    };

    subzeroclawPackage = mkOption {
      type = types.package;
      default = pkgs.subzeroclaw or null;
      description = "Subzeroclaw package to use";
    };

    extraEnvironment = mkOption {
      type = types.attrsOf types.str;
      default = {};
      description = "Additional environment variables";
    };
  };

  config = mkIf cfg.enable {
    # Create agent user
    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.group;
      home = "/var/lib/subzeroclaw";
      createHome = true;
      shell = pkgs.bashInteractive;
    };

    users.groups.${cfg.group} = {};

    # Install all required packages system-wide
    environment.systemPackages = allPackages ++ [
      pkgs.bashInteractive
      pkgs.coreutils
    ];

    # Create directories
    systemd.tmpfiles.rules = [
      "d ${toString cfg.skillsDir} 0755 ${cfg.user} ${cfg.group} -"
      "d ${toString cfg.workDir} 0755 ${cfg.user} ${cfg.group} -"
      "d /var/lib/subzeroclaw 0755 ${cfg.user} ${cfg.group} -"
      "d /var/lib/subzeroclaw/logs 0755 ${cfg.user} ${cfg.group} -"
    ];

    # Agent environment variables
    environment.sessionVariables = {
      SUBZEROCLAW_AGENT_NAME = cfg.name;
      SUBZEROCLAW_SKILLS = toString cfg.skillsDir;
      SUBZEROCLAW_WORKSPACE = toString cfg.workDir;
    } // cfg.extraEnvironment;

    # SSH server for orchestrator connection
    services.openssh = {
      enable = true;
      settings = {
        PasswordAuthentication = false;
        PermitRootLogin = "no";
      };
    };

    # Firewall - allow SSH
    networking.firewall.allowedTCPPorts = [ 22 ];

    # Optional: systemd service for persistent agent
    systemd.services.subzeroclaw-agent = mkIf (cfg.subzeroclawPackage != null) {
      description = "Genswarm Agent - ${cfg.name}";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];

      environment = {
        SUBZEROCLAW_AGENT_NAME = cfg.name;
        SUBZEROCLAW_SKILLS = toString cfg.skillsDir;
        HOME = "/var/lib/subzeroclaw";
      } // cfg.extraEnvironment;

      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        Group = cfg.group;
        WorkingDirectory = toString cfg.workDir;
        ExecStart = "${cfg.subzeroclawPackage}/bin/subzeroclaw";
        Restart = "on-failure";
        RestartSec = "5s";

        # Security hardening
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        ReadWritePaths = [
          "/var/lib/subzeroclaw"
          (toString cfg.workDir)
        ];
      };
    };
  };
}
