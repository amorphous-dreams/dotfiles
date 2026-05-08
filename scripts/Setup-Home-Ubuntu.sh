#!/usr/bin/env bash
# Setup-Home-Ubuntu.sh
# Idempotent post-install setup for WSL2 Ubuntu 24.04 on a personal dev machine.
# Run from inside WSL after initial Ubuntu setup completes.
#
# Usage:
#   bash Setup-Home-Ubuntu.sh              # full setup
#   bash Setup-Home-Ubuntu.sh --skip-docker   # skip Docker CE install
#   bash Setup-Home-Ubuntu.sh --skip-node     # skip nvm/Node install
#   bash Setup-Home-Ubuntu.sh --skip-claude   # skip Claude Code CLI install
#   bash Setup-Home-Ubuntu.sh --dry-run       # preview only, zero changes
#
# Safe to re-run — all steps check before acting.

set -euo pipefail

# ── Flags ─────────────────────────────────────────────────────────────────────

SKIP_DOCKER=false
SKIP_NODE=false
SKIP_CLAUDE=false
DRY_RUN=false

for arg in "$@"; do
  case $arg in
    --skip-docker) SKIP_DOCKER=true ;;
    --skip-node)   SKIP_NODE=true ;;
    --skip-claude) SKIP_CLAUDE=true ;;
    --dry-run)     DRY_RUN=true ;;
  esac
done

# ── Helpers ───────────────────────────────────────────────────────────────────

CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
GRAY='\033[0;90m'
RED='\033[0;31m'
NC='\033[0m'

step()  { echo -e "\n${CYAN}  → $1${NC}"; }
ok()    { echo -e "${GREEN}    ✓ $1${NC}"; }
skip()  { echo -e "${GRAY}    ~ $1${NC}"; }
warn()  { echo -e "${YELLOW}    ! $1${NC}"; }
fail()  { echo -e "${RED}    ✗ $1${NC}"; }

run() {
  if [[ "$DRY_RUN" == true ]]; then
    echo -e "${GRAY}    [dry-run] $*${NC}"
  else
    "$@"
  fi
}

RESTART_REQUIRED=false

# ── Step 1: Check we're in WSL ────────────────────────────────────────────────

step "Checking environment"

if ! grep -qi microsoft /proc/version 2>/dev/null; then
  fail "This script is intended for WSL2 Ubuntu. /proc/version does not indicate WSL."
  exit 1
fi
ok "Running inside WSL2"

UBUNTU_VERSION=$(lsb_release -rs 2>/dev/null || echo "unknown")
ok "Ubuntu $UBUNTU_VERSION"

LINUX_USER=$(whoami)

# ── Step 2: /etc/wsl.conf ─────────────────────────────────────────────────────

step "Configuring /etc/wsl.conf"

# Home setup: keep Windows PATH available (useful for VS Code, Explorer, etc.)
# generateResolvConf=true lets WSL manage DNS automatically — no VPN quirks here
DESIRED_WSL_CONF="[user]
default=${LINUX_USER}

[boot]
systemd=true

[interop]
enabled=true
appendWindowsPath=true"

WSL_CONF_TMP=$(mktemp)
printf '%s' "$DESIRED_WSL_CONF" > "$WSL_CONF_TMP"

if [[ -f /etc/wsl.conf ]]; then
  CURRENT=$(cat /etc/wsl.conf)
  if [[ "$CURRENT" == "$DESIRED_WSL_CONF" ]]; then
    skip "/etc/wsl.conf already up to date"
    rm -f "$WSL_CONF_TMP"
  else
    warn "Updating /etc/wsl.conf (backing up existing)"
    run sudo cp /etc/wsl.conf /etc/wsl.conf.bak.$(date +%Y%m%d-%H%M%S)
    run sudo cp "$WSL_CONF_TMP" /etc/wsl.conf
    rm -f "$WSL_CONF_TMP"
    ok "/etc/wsl.conf updated"
    [[ "$DRY_RUN" == false ]] && RESTART_REQUIRED=true
  fi
else
  run sudo cp "$WSL_CONF_TMP" /etc/wsl.conf
  rm -f "$WSL_CONF_TMP"
  ok "/etc/wsl.conf written"
  [[ "$DRY_RUN" == false ]] && RESTART_REQUIRED=true
fi

if [[ "$RESTART_REQUIRED" == true ]]; then
  warn "wsl.conf changed — WSL restart required after this script finishes."
  warn "Run from PowerShell:  wsl --shutdown && wsl ~"
  warn "Then re-run this script to continue."
fi

# ── Step 3: Git identity ──────────────────────────────────────────────────────

step "Configuring Git identity"

GIT_NAME=$(git config --global user.name 2>/dev/null || echo "")
GIT_EMAIL=$(git config --global user.email 2>/dev/null || echo "")
GIT_BRANCH=$(git config --global init.defaultBranch 2>/dev/null || echo "")

if [[ -n "$GIT_NAME" && -n "$GIT_EMAIL" ]]; then
  skip "Git identity already set: $GIT_NAME <$GIT_EMAIL>"
else
  if [[ "$DRY_RUN" == true ]]; then
    warn "[dry-run] Would prompt for git name and email"
  else
    echo ""
    if [[ -z "$GIT_NAME" ]]; then
      read -r -p "    Git name  (e.g. Josh Fontany): " INPUT_NAME
      if [[ -n "$INPUT_NAME" ]]; then
        git config --global user.name "$INPUT_NAME"
        ok "Git name set: $INPUT_NAME"
      else
        warn "Skipped — set later: git config --global user.name \"Your Name\""
      fi
    fi
    if [[ -z "$GIT_EMAIL" ]]; then
      read -r -p "    Git email (e.g. you@example.com): " INPUT_EMAIL
      if [[ -n "$INPUT_EMAIL" ]]; then
        git config --global user.email "$INPUT_EMAIL"
        ok "Git email set: $INPUT_EMAIL"
      else
        warn "Skipped — set later: git config --global user.email \"you@example.com\""
      fi
    fi
  fi
fi

if [[ "$GIT_BRANCH" == "main" ]]; then
  skip "init.defaultBranch already set to main"
else
  run git config --global init.defaultBranch main
  ok "init.defaultBranch set to main"
fi

run git config --global --add safe.directory '*'
ok "git safe.directory set to '*'"

# ── Step 4: SSH agent ─────────────────────────────────────────────────────────

step "Configuring SSH agent"

SHELL_RC="${HOME}/.bashrc"
[[ -f "${HOME}/.zshrc" ]] && SHELL_RC="${HOME}/.zshrc"

SSH_AGENT_BLOCK='# >>> ssh-agent start <<<
if [ -z "$SSH_AGENT_PID" ] || ! kill -0 "$SSH_AGENT_PID" 2>/dev/null; then
  eval "$(ssh-agent -s)" > /dev/null
fi
if [[ -f ~/.ssh/id_ed25519 ]]; then
  ssh-add -l &>/dev/null || ssh-add ~/.ssh/id_ed25519 2>/dev/null
fi
# <<< ssh-agent end <<<'

if grep -q "ssh-agent start" "$SHELL_RC" 2>/dev/null; then
  skip "SSH agent already configured in $SHELL_RC"
else
  if [[ "$DRY_RUN" == true ]]; then
    echo -e "${GRAY}    [dry-run] Would add SSH agent block to $SHELL_RC${NC}"
  else
    echo "" >> "$SHELL_RC"
    echo "$SSH_AGENT_BLOCK" >> "$SHELL_RC"
  fi
  ok "SSH agent added to $SHELL_RC"
fi

# Check for SSH keys — suggest common Windows locations
if [[ -f ~/.ssh/id_ed25519 ]]; then
  ok "SSH key found at ~/.ssh/id_ed25519"
else
  warn "No SSH key at ~/.ssh/id_ed25519"
  WIN_USER=$(cmd.exe /c "echo %USERNAME%" 2>/dev/null | tr -d '\r\n' || echo "")
  if [[ -n "$WIN_USER" && -f "/mnt/c/Users/${WIN_USER}/.ssh/id_ed25519" ]]; then
    warn "Found key on Windows side — copy with:"
    warn "  mkdir -p ~/.ssh && chmod 700 ~/.ssh"
    warn "  cp /mnt/c/Users/${WIN_USER}/.ssh/id_ed25519 ~/.ssh/"
    warn "  cp /mnt/c/Users/${WIN_USER}/.ssh/id_ed25519.pub ~/.ssh/"
    warn "  chmod 600 ~/.ssh/id_ed25519"
  else
    warn "Generate a new key with:"
    warn "  ssh-keygen -t ed25519 -C \"your@email.com\""
    warn "  cat ~/.ssh/id_ed25519.pub  # add to GitHub → Settings → SSH keys"
  fi
fi

# ── Step 5: Docker CE ─────────────────────────────────────────────────────────

if [[ "$SKIP_DOCKER" == false ]]; then
  step "Installing Docker CE"

  if command -v docker &>/dev/null; then
    skip "Docker already installed: $(docker --version)"
  else
    ok "Installing Docker CE via apt..."

    run sudo apt-get update -qq
    run sudo apt-get install -y -qq ca-certificates curl gnupg

    run sudo install -m 0755 -d /etc/apt/keyrings

    if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
      run bash -c "curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg"
      run sudo chmod a+r /etc/apt/keyrings/docker.gpg
      ok "Docker GPG key added"
    else
      skip "Docker GPG key already present"
    fi

    if [[ ! -f /etc/apt/sources.list.d/docker.list ]]; then
      DOCKER_ARCH=$(dpkg --print-architecture)
      DOCKER_CODENAME=$(. /etc/os-release && echo "$VERSION_CODENAME")
      DOCKER_REPO="deb [arch=${DOCKER_ARCH} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${DOCKER_CODENAME} stable"
      if [[ "$DRY_RUN" == true ]]; then
        echo -e "${GRAY}    [dry-run] Would write docker repo: $DOCKER_REPO${NC}"
      else
        echo "$DOCKER_REPO" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
      fi
      ok "Docker apt repo added"
    else
      skip "Docker apt repo already configured"
    fi

    run sudo apt-get update -qq
    run sudo apt-get install -y -qq \
      docker-ce \
      docker-ce-cli \
      containerd.io \
      docker-buildx-plugin \
      docker-compose-plugin

    ok "Docker CE installed"
  fi

  if groups "$USER" | grep -q docker; then
    skip "$USER already in docker group"
  else
    run sudo usermod -aG docker "$USER"
    ok "$USER added to docker group (restart WSL to apply)"
    [[ "$DRY_RUN" == false ]] && RESTART_REQUIRED=true
  fi

  if systemctl is-enabled docker &>/dev/null 2>&1; then
    skip "Docker service already enabled via systemd"
  elif grep -q "systemd=true" /etc/wsl.conf 2>/dev/null; then
    warn "systemd=true is set — Docker will auto-start after WSL restart"
  else
    if grep -q "service docker start" "$SHELL_RC" 2>/dev/null; then
      skip "Docker service start already in $SHELL_RC"
    else
      if [[ "$DRY_RUN" == true ]]; then
        echo -e "${GRAY}    [dry-run] Would add docker service start to $SHELL_RC${NC}"
      else
        echo "" >> "$SHELL_RC"
        echo "# Start Docker daemon if not running" >> "$SHELL_RC"
        echo "sudo service docker start > /dev/null 2>&1" >> "$SHELL_RC"
      fi
      ok "Docker auto-start added to $SHELL_RC"
    fi
  fi
else
  skip "Docker install skipped (--skip-docker)"
fi

# ── Step 6: nvm + Node LTS ────────────────────────────────────────────────────

if [[ "$SKIP_NODE" == false ]]; then
  step "Installing nvm + Node.js LTS"

  NVM_DIR="${HOME}/.nvm"

  if [[ -d "$NVM_DIR" ]]; then
    skip "nvm already installed at $NVM_DIR"
  else
    ok "Installing nvm..."
    run bash -c "curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash"
    ok "nvm installed"
  fi

  export NVM_DIR="${HOME}/.nvm"
  [[ -s "$NVM_DIR/nvm.sh" ]] && \. "$NVM_DIR/nvm.sh"

  if grep -q "NVM_DIR" "$SHELL_RC" 2>/dev/null; then
    skip "nvm already sourced in $SHELL_RC"
  else
    if [[ "$DRY_RUN" == true ]]; then
      echo -e "${GRAY}    [dry-run] Would add nvm source block to $SHELL_RC${NC}"
    else
      cat >> "$SHELL_RC" << 'NVMEOF'

# >>> nvm start <<<
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"
# <<< nvm end <<<
NVMEOF
    fi
    ok "nvm source block added to $SHELL_RC"
  fi

  if command -v node &>/dev/null; then
    skip "Node.js already installed: $(node --version)"
  else
    ok "Installing Node.js LTS..."
    run nvm install --lts
    ok "Node.js LTS installed"
  fi

  if command -v node &>/dev/null; then
    ok "node $(node --version), npm $(npm --version)"
  fi
else
  skip "nvm/Node install skipped (--skip-node)"
fi

# ── Step 7: Claude Code CLI ───────────────────────────────────────────────────

if [[ "$SKIP_CLAUDE" == false ]]; then
  step "Installing Claude Code CLI"

  export NVM_DIR="${HOME}/.nvm"
  [[ -s "$NVM_DIR/nvm.sh" ]] && \. "$NVM_DIR/nvm.sh"

  if ! command -v npm &>/dev/null; then
    warn "npm not found — install Node.js first (step 6) or re-run without --skip-node"
  elif npm list -g @anthropic-ai/claude-code &>/dev/null 2>&1; then
    CLAUDE_VERSION=$(npm list -g @anthropic-ai/claude-code --depth=0 2>/dev/null | grep claude-code | awk -F@ '{print $NF}')
    skip "Claude Code CLI already installed: $CLAUDE_VERSION"
  else
    ok "Installing @anthropic-ai/claude-code..."
    run npm install -g @anthropic-ai/claude-code
    ok "Claude Code CLI installed"
    warn "Authenticate on first use: claude auth"
  fi
else
  skip "Claude Code CLI install skipped (--skip-claude)"
fi

# ── Step 8: zsh + Starship (optional) ────────────────────────────────────────

step "Optional: zsh + Starship prompt"

if command -v zsh &>/dev/null; then
  skip "zsh already installed: $(zsh --version | head -1)"

  # Make sure Starship is wired up even if zsh was pre-installed
  if command -v starship &>/dev/null; then
    ZSHRC="${HOME}/.zshrc"
    if grep -q "starship init" "$ZSHRC" 2>/dev/null; then
      skip "Starship already configured in .zshrc"
    else
      if [[ "$DRY_RUN" == true ]]; then
        echo -e "${GRAY}    [dry-run] Would add starship init to .zshrc${NC}"
      else
        echo 'eval "$(starship init zsh)"' >> "$ZSHRC"
      fi
      ok "Starship added to .zshrc"
    fi
  fi
else
  if [[ "$DRY_RUN" == true ]]; then
    skip "zsh install prompt skipped in dry-run"
  else
    echo -e "${CYAN}    Install zsh + Starship? (modern shell + smart prompt)${NC}"
    read -r -p "    Install? [y/N] " ZSH_CHOICE
    if [[ "$ZSH_CHOICE" =~ ^[Yy]$ ]]; then
      sudo apt-get install -y -qq zsh
      chsh -s "$(which zsh)"
      ok "zsh installed and set as default shell"

      if command -v starship &>/dev/null; then
        skip "Starship already installed"
      else
        bash -c "curl -sS https://starship.rs/install.sh | sh -s -- --yes" 2>&1 \
          | grep -E "^(>|✓|!)" || true
        ok "Starship installed"
      fi

      ZSHRC="${HOME}/.zshrc"
      [[ ! -f "$ZSHRC" ]] && touch "$ZSHRC"

      if grep -q "starship init" "$ZSHRC" 2>/dev/null; then
        skip "Starship already in .zshrc"
      else
        echo 'eval "$(starship init zsh)"' >> "$ZSHRC"
        ok "Starship added to .zshrc"
      fi

      # Starship scan timeout config
      mkdir -p "${HOME}/.config/starship"
      if [[ ! -f "${HOME}/.config/starship/starship.toml" ]]; then
        cat > "${HOME}/.config/starship/starship.toml" << 'TOMLEOF'
scan_timeout = 10

[directory]
truncate_to_repo = true
TOMLEOF
        ok "Starship config written (~/.config/starship/starship.toml)"
      else
        skip "Starship config already exists"
      fi

      warn "Restart WSL to use zsh as default: wsl --shutdown && wsl ~"
      RESTART_REQUIRED=true
    else
      skip "zsh install skipped"
    fi
  fi
fi

# ── Step 9: Verify ────────────────────────────────────────────────────────────

step "Verifying setup"

if getent hosts github.com &>/dev/null; then
  ok "DNS resolution working"
else
  warn "DNS resolution failed — check /etc/resolv.conf"
fi

if [[ -f ~/.ssh/id_ed25519 ]]; then
  ok "SSH key present"
  SSH_TEST=$(ssh -T git@github.com -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 2>&1 || true)
  if echo "$SSH_TEST" | grep -q "successfully authenticated"; then
    ok "GitHub SSH: $(echo "$SSH_TEST" | grep -v Warning | tr -d '\n')"
  else
    warn "GitHub SSH inconclusive — run: ssh -T git@github.com"
  fi
else
  warn "No SSH key at ~/.ssh/id_ed25519"
fi

if command -v docker &>/dev/null; then
  if docker info &>/dev/null 2>&1; then
    ok "Docker: $(docker --version)"
  else
    warn "Docker installed but daemon not running"
    warn "  Restart WSL: wsl --shutdown && wsl ~"
  fi
fi

if command -v node &>/dev/null; then
  ok "Node.js: $(node --version)  npm: $(npm --version)"
fi

if command -v claude &>/dev/null; then
  ok "Claude Code: $(claude --version 2>/dev/null || echo 'installed')"
fi

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo -e "${CYAN}  ════════════════════════════════════════════${NC}"
echo -e "${CYAN}   Home Dev Lab Setup Complete${NC}"
echo -e "${CYAN}  ════════════════════════════════════════════${NC}"
echo ""
echo -e "  User     : ${LINUX_USER}"
echo -e "  Shell rc : ${SHELL_RC}"
echo ""

if [[ "$RESTART_REQUIRED" == true ]]; then
  echo -e "${YELLOW}  ⚠ Restart WSL to apply all changes:${NC}"
  echo -e "${YELLOW}    wsl --shutdown && wsl ~${NC}"
  echo -e "${YELLOW}    Then re-run: bash Setup-Home-Ubuntu.sh${NC}"
  echo ""
fi

GIT_NAME_NOW=$(git config --global user.name 2>/dev/null || echo "")
GIT_EMAIL_NOW=$(git config --global user.email 2>/dev/null || echo "")

echo -e "  Remaining manual steps:"
[[ -z "$GIT_NAME_NOW" ]]  && echo -e "    git config --global user.name  \"Your Name\""
[[ -z "$GIT_EMAIL_NOW" ]] && echo -e "    git config --global user.email \"you@example.com\""
echo -e "    claude auth        # first-time Claude Code authentication"
echo -e "    ssh -T git@github.com  # verify GitHub SSH if key is new"
echo -e "    code-insiders .    # or: code . to connect VS Code to WSL"
echo ""
echo -e "${GRAY}  VS Code: Ctrl+Shift+X → search 'Claude' → Install in WSL${NC}"
echo ""
