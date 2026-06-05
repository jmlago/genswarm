# Custom bwrap preset template for downstream projects
#
# Copy this file to your project as preset.nix and customize.
#
# Build:
#   nix-build preset.nix
#
# Install as system preset:
#   sudo ln -sf $(readlink result) /run/swarm/sandbox-base/my-preset
#
# Or use directly in agent config:
#   agent :auditor, backend: :bwrap do
#     config presets: [{:custom, "./result"}]  # Path to build output
#   end
#
# Or register the directory for preset lookup:
#   Application.put_env(:genswarm, :extra_preset_dirs, ["./presets"])
#   # Then symlink: ln -sf $(readlink result) ./presets/solidity

{ pkgs ? import <nixpkgs> {}
, subzeroSwarmSrc ? builtins.fetchGit {
    url = "https://github.com/subzeroclaw/genswarm";
    ref = "main";
  }
}:

let
  toolPresets = import "${subzeroSwarmSrc}/nix/tool-presets.nix" { inherit pkgs; };
  sandboxLib = import "${subzeroSwarmSrc}/nix/bwrap-sandbox.nix" { inherit pkgs toolPresets; };
in

sandboxLib.mkSandboxBase {
  # Preset name (used for /run/swarm/sandbox-base/<name>)
  name = "my-custom-preset";

  # Base presets to include from genswarm
  # Available: base, web, code, python, node, data, docs, network, security, ai
  presets = [ "base" "code" ];

  # Your domain-specific packages
  extraPackages = with pkgs; [
    # === Solidity example ===
    # solc
    # slither-analyzer
    # foundry-bin

    # === Python ML example ===
    # (python312.withPackages (ps: with ps; [ numpy pandas torch ]))

    # === Security example ===
    # nmap
    # nikto

    # === Whatever your domain needs ===
    jq
  ];
}
