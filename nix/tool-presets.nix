# Tool presets for Genswarm agents
#
# Presets group related tools together. Agents can reference
# presets in their config or specify individual tools.
#
# Usage in swarm config:
#   %{name: :researcher, tools: [:git, :curl], presets: [:web]}

{ pkgs }:

{
  # ============================================
  # PRESETS - Named groups of tools
  # ============================================

  # Base tools - always useful
  base = with pkgs; [
    coreutils
    bash
    gnugrep
    gnused
    gawk
    findutils
    which
    less
    file
    curl  # Required by subzeroclaw for API calls
    jq    # Required by szc-wrapper for JSON protocol translation
  ];

  # Web/HTTP tools
  web = with pkgs; [
    curl
    wget
    httpie
    jq
    yq
    htmlq          # like jq but for HTML
    w3m            # text browser
    lynx
  ];

  # Code/development tools
  code = with pkgs; [
    git
    git-lfs
    gnumake
    gcc
    ripgrep
    fd
    tree
    diff-so-fancy
    delta          # better git diff
    bat            # better cat
    tokei          # code stats
  ];

  # Python environment
  python = with pkgs; [
    python312
    python312Packages.pip
    python312Packages.virtualenv
    python312Packages.requests
    python312Packages.beautifulsoup4
    python312Packages.pandas
    python312Packages.numpy
  ];

  # Node.js environment
  node = with pkgs; [
    nodejs_20
    nodePackages.npm
    nodePackages.yarn
    nodePackages.pnpm
  ];

  # Data processing
  data = with pkgs; [
    jq
    yq
    csvkit
    miller         # like awk for CSV/JSON
    sqlite
    duckdb
    xsv            # fast CSV toolkit
  ];

  # Document processing
  docs = with pkgs; [
    pandoc
    texlive.combined.scheme-small
    poppler_utils  # pdftotext etc
    ghostscript
    imagemagick
  ];

  # Network/API tools
  network = with pkgs; [
    curl
    wget
    httpie
    netcat
    socat
    openssh
    rsync
    aria2          # download manager
  ];

  # System/debugging tools
  system = with pkgs; [
    htop
    btop
    lsof
    strace
    procps
    psmisc
    pciutils
    usbutils
  ];

  # Security/crypto tools
  security = with pkgs; [
    openssl
    gnupg
    age
    sops
    pass
  ];

  # Container/virtualization tools
  containers = with pkgs; [
    docker-client
    podman
    skopeo
    dive           # explore docker images
  ];

  # Cloud CLI tools
  cloud = with pkgs; [
    awscli2
    google-cloud-sdk
    azure-cli
    kubectl
    k9s
    terraform
  ];

  # AI/ML tools (lightweight)
  ai = with pkgs; [
    python312Packages.openai
    python312Packages.anthropic
    python312Packages.tiktoken
  ];

  # ============================================
  # INDIVIDUAL TOOLS - For fine-grained control
  # ============================================
  # These can be referenced individually in the tools list

  # Map tool names to packages for direct reference
  tools = with pkgs; {
    # Basics
    git = git;
    curl = curl;
    wget = wget;
    jq = jq;
    yq = yq;
    tree = tree;
    htop = htop;

    # Search/find
    ripgrep = ripgrep;
    rg = ripgrep;
    fd = fd;
    fzf = fzf;
    ag = silver-searcher;

    # Editors (for agents that need to edit files)
    vim = vim;
    neovim = neovim;
    nano = nano;

    # Languages
    python = python312;
    python3 = python312;
    node = nodejs_20;
    nodejs = nodejs_20;
    ruby = ruby;
    go = go;
    rustc = rustc;
    cargo = cargo;

    # Build tools
    make = gnumake;
    cmake = cmake;
    gcc = gcc;
    clang = clang;

    # Databases
    sqlite = sqlite;
    postgresql = postgresql;
    mysql = mysql;
    redis = redis;
    duckdb = duckdb;

    # Document tools
    pandoc = pandoc;
    pdftotext = poppler_utils;

    # Network
    ssh = openssh;
    rsync = rsync;
    netcat = netcat;
    httpie = httpie;

    # Containers
    docker = docker-client;
    podman = podman;
    kubectl = kubectl;

    # Version control
    gh = gh;          # GitHub CLI
    glab = glab;      # GitLab CLI

    # JSON/data
    miller = miller;
    csvkit = csvkit;
    xsv = xsv;

    # Misc
    ffmpeg = ffmpeg;
    imagemagick = imagemagick;
  };
}
