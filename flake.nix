{
  description = "Genswarm - Elixir/OTP orchestrator for agent swarms";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    let
      # System-independent outputs
      lib = {
        # NixOS modules
        nixosModules.agent = import ./nix/agent-module.nix;
        nixosModules.bwrap = import ./nix/bwrap-module.nix;

        # Helper to create agent node config for Colmena
        mkAgentNode = { name, presets ? [ "base" ], tools ? [], skills ? [], ... }@args: {
          imports = [ self.lib.nixosModules.agent ];
          swarm.agent = {
            enable = true;
            inherit name presets tools skills;
          } // (builtins.removeAttrs args [ "name" "presets" "tools" "skills" ]);
        };

        # Generate Colmena config from swarm config
        mkColmenaFromSwarm = { swarmConfig, defaults ? {} }:
          let
            sshAgents = builtins.filter
              (a: builtins.match "\\{:ssh,.*" (builtins.toString a.backend) != null)
              swarmConfig.agents;
          in
          {
            meta = {
              nixpkgs = nixpkgs;
            };
            defaults = { ... }: defaults;
          } // builtins.listToAttrs (map (agent: {
            name = builtins.toString agent.name;
            value = self.lib.mkAgentNode {
              name = builtins.toString agent.name;
              presets = agent.presets or [ "base" ];
              tools = agent.tools or [];
              skills = agent.skills or [];
            };
          }) sshAgents);
      };

    in
    # Per-system outputs
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        # Elixir/Erlang for the orchestrator
        erlang = pkgs.beam.packages.erlang_27;
        elixir = erlang.elixir_1_17;

        # Tool presets
        toolPresets = import ./nix/tool-presets.nix { inherit pkgs; };

        # Container builder
        containerLib = import ./nix/container.nix { inherit pkgs toolPresets; };

        # Bwrap sandbox builder (for 10k+ agent scale)
        sandboxLib = import ./nix/bwrap-sandbox.nix { inherit pkgs toolPresets; };

        # Mix deps for the project (fetched with network, cached by hash)
        mixDeps = pkgs.beamPackages.fetchMixDeps {
          pname = "subzeroclaw-swarm-deps";
          version = "0.1.0";
          src = ./.;
          hash = "sha256-6QnjY0G8sY2lE8I3JfPzbo8mXYq03KHCu6JVYP5tmvM=";
        };

        # Development shell
        devShell = pkgs.mkShell {
          buildInputs = [
            elixir
            erlang.erlang
            pkgs.nodejs_20
            pkgs.inotify-tools
            pkgs.git
            pkgs.colmena        # For deploying to bare metal
          ];

          shellHook = ''
            export MIX_HOME=$PWD/.nix-mix
            export HEX_HOME=$PWD/.nix-hex
            export PATH=$MIX_HOME/bin:$HEX_HOME/bin:$PATH
            export ERL_AFLAGS="-kernel shell_history enabled"
            echo "Genswarm dev shell"
            echo ""
            echo "Commands:"
            echo "  mix deps.get && mix phx.server  # Start orchestrator"
            echo "  nix build .#agentContainer-web  # Build Docker container"
            echo "  colmena apply                   # Deploy to bare metal nodes"
          '';
        };

      in {
        # Development shell
        devShells.default = devShell;

        # Packages
        packages = {
          default = self.packages.${system}.orchestrator;

          # The orchestrator Phoenix application
          orchestrator = pkgs.beamPackages.mixRelease {
            pname = "genswarm";
            version = "0.1.0";
            src = ./.;
            mixEnv = "prod";
            nativeBuildInputs = [ pkgs.nodejs_20 ];
            mixFodDeps = mixDeps;
          };

          # Standalone swarm CLI escript
          # Uses buildMix which doesn't wrap executables
          swarm-cli = pkgs.beamPackages.buildMix {
            name = "swarm-cli";
            version = "0.1.0";
            src = ./.;

            beamDeps = [];

            nativeBuildInputs = [ pkgs.beamPackages.rebar3 ];

            # Provide rebar3 path
            MIX_REBAR3 = "${pkgs.beamPackages.rebar3}/bin/rebar3";

            # Use pre-fetched deps
            configurePhase = ''
              runHook preConfigure
              cp -r ${mixDeps} deps
              chmod -R u+w deps
              runHook postConfigure
            '';

            # Build escript
            buildPhase = ''
              runHook preBuild
              mix deps.compile --force
              mix escript.build --force
              runHook postBuild
            '';

            # Install with a wrapper script
            installPhase = ''
              runHook preInstall
              mkdir -p $out/bin $out/lib

              # Copy the raw escript
              cp swarm $out/lib/swarm.escript

              # Create wrapper with $out expanded
              cat > $out/bin/swarm << EOF
              #!/bin/sh
              exec ${erlang.erlang}/bin/escript $out/lib/swarm.escript "\$@"
              EOF
              chmod +x $out/bin/swarm

              runHook postInstall
            '';
          };

          # Pre-built container images (NixOS-based)
          agentContainer-base = containerLib.mkAgentContainer containerLib.images.base;
          agentContainer-web = containerLib.mkAgentContainer containerLib.images.web;
          agentContainer-code = containerLib.mkAgentContainer containerLib.images.code;
          agentContainer-data = containerLib.mkAgentContainer containerLib.images.data;
          agentContainer-full = containerLib.mkAgentContainer containerLib.images.full;
          agentContainer-python = containerLib.mkAgentContainer containerLib.images.python;
          agentContainer-node = containerLib.mkAgentContainer containerLib.images.node;
          agentContainer-devops = containerLib.mkAgentContainer containerLib.images.devops;

          # Bwrap sandbox base environments (for 10k+ agent scale)
          # These are symlinked to /run/swarm/sandbox-base/ by the NixOS module
          sandboxBase-base = sandboxLib.base;
          sandboxBase-web = sandboxLib.web;
          sandboxBase-code = sandboxLib.code;
          sandboxBase-data = sandboxLib.data;
          sandboxBase-python = sandboxLib.python;
          sandboxBase-node = sandboxLib.node;
          sandboxBase-web-code = sandboxLib.web-code;
          sandboxBase-code-python = sandboxLib.code-python;
          sandboxBase-data-python = sandboxLib.data-python;
          sandboxBase-full = sandboxLib.full;
          sandboxBase-devops = sandboxLib.devops;
        };

        # Library for custom builds
        lib = {
          inherit toolPresets;
          inherit (containerLib) mkAgentContainer images;
          inherit (sandboxLib) mkSandboxBase;
          sandboxBases = sandboxLib;
        };
      }
    ) // {
      # System-independent outputs
      inherit lib;
      nixosModules = lib.nixosModules;

      # Example Colmena configuration
      # Copy to your own flake and customize
      colmenaExample = {
        meta = {
          nixpkgs = import nixpkgs { system = "x86_64-linux"; };
        };

        defaults = { pkgs, ... }: {
          # Common config for all agent nodes
          time.timeZone = "UTC";
          i18n.defaultLocale = "en_US.UTF-8";
        };

        # Example agent nodes
        researcher = { name, ... }: {
          imports = [ self.lib.nixosModules.agent ];

          deployment = {
            targetHost = "192.168.1.51";
            targetUser = "root";
            tags = [ "swarm" "research" ];
          };

          swarm.agent = {
            enable = true;
            name = "researcher";
            presets = [ "base" "web" ];
            tools = [ "ripgrep" "fd" "jq" ];
            skills = [ "web.md" ];
          };
        };

        coder = { name, ... }: {
          imports = [ self.lib.nixosModules.agent ];

          deployment = {
            targetHost = "192.168.1.52";
            targetUser = "root";
            tags = [ "swarm" "dev" ];
          };

          swarm.agent = {
            enable = true;
            name = "coder";
            presets = [ "base" "code" "python" ];
            tools = [ "docker" "gh" ];
            skills = [ "code.md" ];
          };
        };

        data-processor = { name, ... }: {
          imports = [ self.lib.nixosModules.agent ];

          deployment = {
            targetHost = "192.168.1.53";
            targetUser = "root";
            tags = [ "swarm" "data" ];
          };

          swarm.agent = {
            enable = true;
            name = "data-processor";
            presets = [ "base" "data" "python" ];
            tools = [ "duckdb" "sqlite" ];
            skills = [ "code.md" ];
          };
        };
      };
    };
}
