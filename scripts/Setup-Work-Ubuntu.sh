#!/usr/bin/env bash
# Setup-Work-Ubuntu.sh
# Idempotent post-install setup for WSL2 Ubuntu 24.04 on corporate dev boxes.
# Run from inside WSL after Setup-WSL2.ps1 completes.
#
# Usage:
#   bash Setup-Work-Ubuntu.sh                    # full setup
#   bash Setup-Work-Ubuntu.sh --skip-docker      # skip Docker CE install
#   bash Setup-Work-Ubuntu.sh --skip-node        # skip nvm/Node install
#   bash Setup-Work-Ubuntu.sh --skip-claude      # skip Claude Code CLI install
#   bash Setup-Work-Ubuntu.sh --dry-run          # preview only, no changes
#
# Safe to re-run — all steps check before acting.

set -euo pipefail

# ── Flags ─────────────────────────────────────────────────────────────────────

SKIP_DOCKER=false
SKIP_NODE=false
SKIP_CLAUDE=false
SKIP_CORP_NETWORK=false
DRY_RUN=false

for arg in "$@"; do
  case $arg in
    --skip-docker)       SKIP_DOCKER=true ;;
    --skip-node)         SKIP_NODE=true ;;
    --skip-claude)       SKIP_CLAUDE=true ;;
    --skip-corp-network) SKIP_CORP_NETWORK=true ;;
    --home)              SKIP_CORP_NETWORK=true ;;
    --dry-run)           DRY_RUN=true ;;
  esac
done

# ── Helpers ───────────────────────────────────────────────────────────────────

BOLD='\033[1m'
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

# ── Step 2: /etc/wsl.conf ─────────────────────────────────────────────────────

step "Configuring /etc/wsl.conf"

LINUX_USER=$(whoami)
if [[ "$SKIP_CORP_NETWORK" == true ]]; then
  # Home mode: only set user default + systemd, skip network/interop
  warn "--home: skipping network and interop settings in wsl.conf"
  DESIRED_WSL_CONF="[user]
default=${LINUX_USER}

[boot]
systemd=true"
else
  DESIRED_WSL_CONF="[user]
  default=${LINUX_USER}
  
  [network]
  generateResolvConf=false
  
  [interop]
  appendWindowsPath=false
  
  [boot]
  systemd=true"
fi

# Write wsl.conf via temp file so dry-run is properly gated
WSL_CONF_TMP=$(mktemp)
cat > "$WSL_CONF_TMP" << 'WSLCONF'
WSLCONF_PLACEHOLDER
WSLCONF
# Overwrite placeholder with actual content (variable expansion needed)
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
  warn "wsl.conf changed — a WSL restart is required."
  warn "After this script finishes, run from PowerShell:"
  warn "  wsl --shutdown && wsl ~"
  warn "Then re-run this script to continue remaining steps."
fi

# ── Step 3: /etc/resolv.conf ──────────────────────────────────────────────────

step "Configuring DNS (/etc/resolv.conf)"

if [[ "$SKIP_CORP_NETWORK" == true ]]; then
  skip "DNS config skipped (--skip-corp-network) — WSL will auto-manage resolv.conf"
else
  DESIRED_RESOLV="nameserver 10.0.3.1
nameserver 10.0.3.2
nameserver 8.8.8.8"

  # Write via temp file so dry-run is properly gated
  RESOLV_TMP=$(mktemp)
  printf '%s
' "nameserver 10.0.3.1" "nameserver 10.0.3.2" "nameserver 8.8.8.8" > "$RESOLV_TMP"

  # Remove immutable flag for comparison/update
  if [[ "$DRY_RUN" == false ]]; then
    sudo chattr -i /etc/resolv.conf 2>/dev/null || true
  fi

  if [[ -f /etc/resolv.conf ]]; then
    CURRENT_RESOLV=$(cat /etc/resolv.conf)
    if [[ "$CURRENT_RESOLV" == "$DESIRED_RESOLV" ]]; then
      skip "/etc/resolv.conf already configured"
      rm -f "$RESOLV_TMP"
    else
      run sudo cp "$RESOLV_TMP" /etc/resolv.conf
      rm -f "$RESOLV_TMP"
      ok "/etc/resolv.conf updated (CC VPN DNS + Google fallback)"
    fi
  else
    run sudo cp "$RESOLV_TMP" /etc/resolv.conf
    rm -f "$RESOLV_TMP"
    ok "/etc/resolv.conf written"
  fi

  # Lock resolv.conf from being overwritten by WSL
  if [[ "$DRY_RUN" == false ]]; then
    if sudo chattr +i /etc/resolv.conf 2>/dev/null; then
      ok "/etc/resolv.conf locked (immutable)"
    else
      warn "Could not lock /etc/resolv.conf with chattr (non-critical)"
    fi
  fi
fi

# ── Step 4: Git identity ──────────────────────────────────────────────────────

step "Checking Git identity"

GIT_NAME=$(git config --global user.name 2>/dev/null || echo "")
GIT_EMAIL=$(git config --global user.email 2>/dev/null || echo "")
GIT_BRANCH=$(git config --global init.defaultBranch 2>/dev/null || echo "")

if [[ -n "$GIT_NAME" && -n "$GIT_EMAIL" ]]; then
  skip "Git identity already set: $GIT_NAME <$GIT_EMAIL>"
else
  warn "Git identity not set. Configure manually:"
  warn "  git config --global user.name \"Your Name\""
  warn "  git config --global user.email \"you@consumercellular.com\""
fi

if [[ "$GIT_BRANCH" == "main" ]]; then
  skip "init.defaultBranch already set to main"
else
  run git config --global init.defaultBranch main
  ok "init.defaultBranch set to main"
fi

run git config --global --add safe.directory '*'
ok "git safe.directory set to '*'"

# ── Step 5: SSH agent in shell rc ─────────────────────────────────────────────

step "Configuring SSH agent"

SHELL_RC="${HOME}/.bashrc"
[[ -f "${HOME}/.zshrc" ]] && SHELL_RC="${HOME}/.zshrc"

SSH_AGENT_BLOCK="# >>> ssh-agent start <<<
if [ -z \"\$SSH_AGENT_PID\" ] || ! kill -0 \"\$SSH_AGENT_PID\" 2>/dev/null; then
  eval \"\$(ssh-agent -s)\" > /dev/null
fi
if [[ -f ~/.ssh/id_ed25519 ]]; then
  ssh-add -l &>/dev/null || ssh-add ~/.ssh/id_ed25519 2>/dev/null
fi
# <<< ssh-agent end <<<"

if grep -q "ssh-agent start" "$SHELL_RC" 2>/dev/null; then
  skip "SSH agent already configured in $SHELL_RC"
else
  run bash -c "echo '' >> '$SHELL_RC' && echo '$SSH_AGENT_BLOCK' >> '$SHELL_RC'"
  ok "SSH agent added to $SHELL_RC"
fi

if [[ -f ~/.ssh/id_ed25519 ]]; then
  ok "SSH key found at ~/.ssh/id_ed25519"
else
  warn "No SSH key at ~/.ssh/id_ed25519 — copy from Windows side:"
  warn "  cp /mnt/c/Users/\$USER/.ssh/id_ed25519 ~/.ssh/"
  warn "  cp /mnt/c/Users/\$USER/.ssh/id_ed25519.pub ~/.ssh/"
  warn "  chmod 600 ~/.ssh/id_ed25519"
fi

# ── Step 6: Docker CE ─────────────────────────────────────────────────────────

if [[ "$SKIP_DOCKER" == false ]]; then
  step "Installing Docker CE (NOM Container Tool Decision, May 2025)"

  if command -v docker &>/dev/null; then
    DOCKER_VERSION=$(docker --version 2>/dev/null)
    skip "Docker already installed: $DOCKER_VERSION"
  else
    ok "Installing Docker CE via apt (not get.docker.com — bypasses WSL redirect)"

    run sudo apt-get update -qq
    run sudo apt-get install -y -qq ca-certificates curl gnupg

    # Add Docker GPG key
    run sudo install -m 0755 -d /etc/apt/keyrings
    if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
      run bash -c "curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg"
      run sudo chmod a+r /etc/apt/keyrings/docker.gpg
      ok "Docker GPG key added"
    else
      skip "Docker GPG key already present"
    fi

    # Add Docker apt repo
    if [[ ! -f /etc/apt/sources.list.d/docker.list ]]; then
      DOCKER_ARCH=$(dpkg --print-architecture)
      DOCKER_CODENAME=$(. /etc/os-release && echo "$VERSION_CODENAME")
      DOCKER_REPO="deb [arch=${DOCKER_ARCH} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${DOCKER_CODENAME} stable"
      if [[ "$DRY_RUN" == true ]]; then
        skip "[dry-run] Would write docker repo: $DOCKER_REPO"
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

  # docker group membership
  if groups "$USER" | grep -q docker; then
    skip "$USER already in docker group"
  else
    run sudo usermod -aG docker "$USER"
    ok "$USER added to docker group (restart WSL to apply)"
    [[ "$DRY_RUN" == false ]] && RESTART_REQUIRED=true
  fi

  # systemd will handle docker start if enabled — check
  if systemctl is-enabled docker &>/dev/null 2>&1; then
    skip "Docker service already enabled via systemd"
  elif [[ -f /etc/wsl.conf ]] && grep -q "systemd=true" /etc/wsl.conf; then
    warn "systemd=true is set — Docker will auto-start after WSL restart"
  else
    # Fallback: add service start to bashrc
    if grep -q "service docker start" "$SHELL_RC" 2>/dev/null; then
      skip "Docker service start already in $SHELL_RC"
    else
      run bash -c "echo '' >> '$SHELL_RC'"
      run bash -c "echo '# Start Docker daemon if not running' >> '$SHELL_RC'"
      run bash -c "echo 'sudo service docker start > /dev/null 2>&1' >> '$SHELL_RC'"
      ok "Docker auto-start added to $SHELL_RC"
    fi
  fi
else
  skip "Docker CE install skipped (--skip-docker)"
fi

# ── Step 7: nvm + Node LTS ────────────────────────────────────────────────────

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

  # Source nvm for use in this script session
  export NVM_DIR="${HOME}/.nvm"
  # shellcheck source=/dev/null
  [[ -s "$NVM_DIR/nvm.sh" ]] && \. "$NVM_DIR/nvm.sh"

  # Ensure nvm source block is in shell rc
  if grep -q "NVM_DIR" "$SHELL_RC" 2>/dev/null; then
    skip "nvm already sourced in $SHELL_RC"
  else
    run bash -c "cat >> '$SHELL_RC' << 'NVMEOF'

# >>> nvm start <<<
export NVM_DIR=\"\$HOME/.nvm\"
[ -s \"\$NVM_DIR/nvm.sh\" ] && \. \"\$NVM_DIR/nvm.sh\"
[ -s \"\$NVM_DIR/bash_completion\" ] && \. \"\$NVM_DIR/bash_completion\"
# <<< nvm end <<<
NVMEOF"
    ok "nvm source block added to $SHELL_RC"
  fi

  # Install Node LTS if not present
  if command -v node &>/dev/null; then
    NODE_VERSION=$(node --version 2>/dev/null)
    skip "Node.js already installed: $NODE_VERSION"
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

# ── Step 8: Claude Code CLI ───────────────────────────────────────────────────

if [[ "$SKIP_CLAUDE" == false ]]; then
  step "Installing Claude Code CLI"

  # Ensure npm is available
  export NVM_DIR="${HOME}/.nvm"
  [[ -s "$NVM_DIR/nvm.sh" ]] && \. "$NVM_DIR/nvm.sh"

  if ! command -v npm &>/dev/null; then
    warn "npm not found — install Node.js first (step 7) or re-run without --skip-node"
    warn "Skipping Claude Code CLI install"
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

# ── Step 9: zsh + Starship (optional — prompts user) ─────────────────────────

step "Optional: zsh + Starship prompt"

if command -v zsh &>/dev/null; then
  skip "zsh already installed: $(zsh --version | head -1)"
else
  if [[ "$DRY_RUN" == true ]]; then
    skip "zsh install prompt skipped in dry-run — re-run without --dry-run to install"
  else
  echo -e "${CYAN}    Install zsh + Starship prompt? (recommended for better terminal experience)${NC}"
  read -r -p "    Install? [y/N] " ZSH_CHOICE
  if [[ "$ZSH_CHOICE" =~ ^[Yy]$ ]]; then
    run sudo apt-get install -y -qq zsh
    run chsh -s "$(which zsh)"
    ok "zsh installed and set as default shell"

    if command -v starship &>/dev/null; then
      skip "Starship already installed"
    else
      run bash -c "curl -sS https://starship.rs/install.sh | sh -s -- --yes"
      ok "Starship installed"
    fi

    ZSHRC="${HOME}/.zshrc"
    if [[ ! -f "$ZSHRC" ]]; then
      run touch "$ZSHRC"
    fi

    if grep -q "starship init" "$ZSHRC" 2>/dev/null; then
      skip "Starship already in .zshrc"
    else
      run bash -c "echo 'eval \"\$(starship init zsh)\"' >> '$ZSHRC'"
      ok "Starship added to .zshrc"
    fi

    warn "Log out and back in (wsl --shutdown) to use zsh as default shell"
    [[ "$DRY_RUN" == false ]] && RESTART_REQUIRED=true
  else
    skip "zsh install skipped"
  fi
  fi  # end dry-run gate
fi

# ── Step 10: Verify ───────────────────────────────────────────────────────────

step "Verifying setup"

# DNS
if getent hosts github.com &>/dev/null; then
  ok "DNS resolution working"
else
  warn "DNS resolution failed — check /etc/resolv.conf"
fi

# SSH key
if [[ -f ~/.ssh/id_ed25519 ]]; then
  ok "SSH key present"
  SSH_TEST=$(ssh -T git@github.com -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 2>&1 || true)
  if echo "$SSH_TEST" | grep -q "successfully authenticated"; then
    ok "GitHub SSH: $(echo "$SSH_TEST" | grep -v Warning | tr -d '\n')"
  else
    warn "GitHub SSH test inconclusive — run: ssh -T git@github.com"
  fi
else
  warn "No SSH key found at ~/.ssh/id_ed25519"
fi

# Docker
if command -v docker &>/dev/null; then
  if docker info &>/dev/null 2>&1; then
    ok "Docker daemon running: $(docker --version)"
  else
    warn "Docker installed but daemon not running"
    warn "  If systemd=true is set: restart WSL (wsl --shutdown)"
    warn "  Otherwise: sudo service docker start"
  fi
fi

# Node
if command -v node &>/dev/null; then
  ok "Node.js: $(node --version)  npm: $(npm --version)"
fi

# Claude Code
if command -v claude &>/dev/null; then
  ok "Claude Code CLI: $(claude --version 2>/dev/null || echo 'installed')"
fi

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo -e "${CYAN}  ════════════════════════════════════════════${NC}"
echo -e "${CYAN}   Ubuntu Setup Complete${NC}"
echo -e "${CYAN}  ════════════════════════════════════════════${NC}"
echo ""
echo -e "  User     : ${LINUX_USER}"
echo -e "  Shell rc : ${SHELL_RC}"
echo ""

if [[ "$RESTART_REQUIRED" == true ]]; then
  echo -e "${YELLOW}  ⚠ WSL restart required to apply all changes:${NC}"
  echo -e "${YELLOW}    From PowerShell: wsl --shutdown && wsl ~${NC}"
  echo -e "${YELLOW}    Then re-run:     bash Setup-Work-Ubuntu.sh${NC}"
  echo ""
fi

echo -e "  Remaining manual steps:"
echo -e "    git config --global user.name  \"Your Name\""
echo -e "    git config --global user.email \"you@consumercellular.com\""
echo -e "    claude auth   (first-time Claude Code authentication)"
echo -e "    code-insiders .  (connect VS Code Insiders to WSL)"
echo ""
echo -e "${GRAY}  VS Code extension: Ctrl+Shift+X → search 'Claude' → Install in WSL${NC}"
echo ""
