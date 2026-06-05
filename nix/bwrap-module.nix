# NixOS module for Genswarm bwrap backend
#
# Configures the system for running 10k+ agents using bubblewrap sandboxing.
#
# Usage in configuration.nix:
#   imports = [ ./path/to/bwrap-module.nix ];
#   services.subzeroclaw-bwrap = {
#     enable = true;
#     maxAgents = 10000;
#     sandboxPresets = [ "base" "web" "code" ];
#   };

{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.subzeroclaw-bwrap;

  toolPresets = import ./tool-presets.nix { inherit pkgs; };
  sandboxLib = import ./bwrap-sandbox.nix { inherit pkgs toolPresets; };

  # Calculate system limits based on max agents
  # Conservative estimates for 10k scale
  calculateLimits = maxAgents: {
    fileMax = maxAgents * 200;          # ~200 FDs per agent
    mountMax = maxAgents * 3 + 10000;   # ~3 mounts per agent + buffer
    pidMax = maxAgents * 10 + 100000;   # ~10 processes per agent + system
    inotifyMax = maxAgents * 10;        # inotify watches
    tmpfsSize = "${toString (maxAgents * 5 + 1000)}M";  # ~5MB per agent overlay
  };

  limits = calculateLimits cfg.maxAgents;

in {
  options.services.subzeroclaw-bwrap = {
    enable = mkEnableOption "Genswarm bwrap backend";

    maxAgents = mkOption {
      type = types.int;
      default = 10000;
      description = "Maximum number of concurrent agents to support";
    };

    sandboxPresets = mkOption {
      type = types.listOf types.str;
      default = [ "base" "web" "code" "data" "python" "full" ];
      description = "Which sandbox preset environments to pre-build";
    };

    tmpfsSize = mkOption {
      type = types.str;
      default = limits.tmpfsSize;
      description = "Size of tmpfs for agent overlays";
    };

    memoryLimitPerAgent = mkOption {
      type = types.str;
      default = "256M";
      description = "Default memory limit per agent";
    };

    cpuSharesPerAgent = mkOption {
      type = types.int;
      default = 100;
      description = "Default CPU shares per agent";
    };

    user = mkOption {
      type = types.str;
      default = "subzeroclaw";
      description = "User to run the swarm orchestrator as";
    };

    group = mkOption {
      type = types.str;
      default = "subzeroclaw";
      description = "Group for swarm processes";
    };
  };

  config = mkIf cfg.enable {
    # Required packages
    environment.systemPackages = with pkgs; [
      bubblewrap
      fuse-overlayfs
      fuse
    ];

    # Enable user namespaces (required for rootless bwrap)
    boot.kernel.sysctl = {
      "kernel.unprivileged_userns_clone" = 1;

      # System limits for 10k scale
      "fs.file-max" = limits.fileMax;
      "fs.mount-max" = limits.mountMax;
      "kernel.pid_max" = limits.pidMax;

      # inotify limits
      "fs.inotify.max_user_instances" = limits.inotifyMax;
      "fs.inotify.max_user_watches" = limits.inotifyMax * 10;

      # Network tuning for many processes
      "net.core.somaxconn" = 65535;
      "net.ipv4.tcp_max_syn_backlog" = 65535;
      "net.core.netdev_max_backlog" = 65535;

      # Memory overcommit settings
      "vm.overcommit_memory" = 1;
      "vm.max_map_count" = cfg.maxAgents * 100;
    };

    # Create subzeroclaw user if it doesn't exist
    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.group;
      home = "/var/lib/subzeroclaw";
      createHome = true;
      shell = pkgs.bash;
      # Allow user namespace operations
      subUidRanges = [{ startUid = 100000; count = 65536; }];
      subGidRanges = [{ startGid = 100000; count = 65536; }];
    };

    users.groups.${cfg.group} = {};

    # Tmpfs for agent sandboxes
    fileSystems."/run/swarm" = {
      device = "tmpfs";
      fsType = "tmpfs";
      options = [
        "size=${cfg.tmpfsSize}"
        "mode=755"
        "uid=${cfg.user}"
        "gid=${cfg.group}"
      ];
    };

    # Create sandbox base directory structure
    systemd.tmpfiles.rules = [
      "d /run/swarm/sandbox-base 0755 ${cfg.user} ${cfg.group} -"
      "d /run/swarm/agents 0755 ${cfg.user} ${cfg.group} -"
      "d /var/lib/subzeroclaw 0755 ${cfg.user} ${cfg.group} -"
      "d /var/lib/subzeroclaw/skills 0755 ${cfg.user} ${cfg.group} -"
      "d /var/lib/subzeroclaw/workspaces 0755 ${cfg.user} ${cfg.group} -"
    ] ++
    # Symlink pre-built sandbox bases
    (map (preset:
      let
        sandboxEnv = sandboxLib.${preset} or sandboxLib.base;
      in "L+ /run/swarm/sandbox-base/${preset} - - - - ${sandboxEnv}"
    ) cfg.sandboxPresets);

    # Systemd slice for resource accounting
    systemd.slices.subzeroclaw = {
      description = "Genswarm Agent Slice";
      sliceConfig = {
        MemoryAccounting = true;
        CPUAccounting = true;
        TasksAccounting = true;
        IOAccounting = true;

        # Slice-level limits (aggregate for all agents)
        # These are soft limits - individual scopes have hard limits
        MemoryHigh = "${toString (cfg.maxAgents * 300)}M";
        TasksMax = cfg.maxAgents * 20;
      };
    };

    # User service for the orchestrator
    systemd.user.services.subzeroclaw-swarm = {
      description = "Genswarm Orchestrator";
      wantedBy = [ "default.target" ];
      after = [ "network.target" ];

      environment = {
        HOME = "/var/lib/subzeroclaw";
        SWARM_BASE_DIR = "/run/swarm";
        SWARM_MEMORY_LIMIT = cfg.memoryLimitPerAgent;
        SWARM_CPU_SHARES = toString cfg.cpuSharesPerAgent;
      };

      serviceConfig = {
        Type = "simple";
        Restart = "on-failure";
        RestartSec = "5s";

        # Security hardening (orchestrator itself)
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = "read-only";
        ReadWritePaths = [
          "/run/swarm"
          "/var/lib/subzeroclaw"
          "/tmp"
        ];
      };
    };

    # Allow fuse for the user
    programs.fuse.userAllowOther = true;

    # Security limits for the user
    security.pam.loginLimits = [
      {
        domain = cfg.user;
        type = "soft";
        item = "nofile";
        value = toString (limits.fileMax / 10);  # Per-user limit
      }
      {
        domain = cfg.user;
        type = "hard";
        item = "nofile";
        value = toString limits.fileMax;
      }
      {
        domain = cfg.user;
        type = "soft";
        item = "nproc";
        value = toString (limits.pidMax / 10);
      }
      {
        domain = cfg.user;
        type = "hard";
        item = "nproc";
        value = toString limits.pidMax;
      }
    ];

    # Polkit rules for systemd user scopes (if needed)
    security.polkit.extraConfig = ''
      polkit.addRule(function(action, subject) {
        if (action.id == "org.freedesktop.systemd1.manage-units" &&
            subject.user == "${cfg.user}" &&
            action.lookup("unit").indexOf("szc-") == 0) {
          return polkit.Result.YES;
        }
      });
    '';
  };
}
