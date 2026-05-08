#!/usr/bin/env bash
# install.sh — bootstrap chezmoi and apply dotfiles
# Idempotent — safe to re-run at any time.
#
# Usage:
#   bash install.sh              # full install/update
#   bash install.sh --dry-run    # preview changes, no writes
#   bash install.sh --update     # pull latest from GitHub + re-apply
#   bash install.sh --re-prompt  # clear cached answers and re-prompt

set -euo pipefail

CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
GRAY='\033[0;90m'; RED='\033[0;31m'; NC='\033[0m'

step()  { echo -e "\n${CYAN}  → $1${NC}"; }
ok()    { echo -e "${GREEN}    ✓ $1${NC}"; }
skip()  { echo -e "${GRAY}    ~ $1${NC}"; }
warn()  { echo -e "${YELLOW}    ! $1${NC}"; }
fail()  { echo -e "${RED}    ✗ $1${NC}"; exit 1; }

DRY_RUN=false; DO_UPDATE=false; RE_PROMPT=false
GITHUB_ORG="amorphous-dreams"; REPO="dotfiles"

for arg in "$@"; do
  case $arg in
    --dry-run)   DRY_RUN=true ;;
    --update)    DO_UPDATE=true ;;
    --re-prompt) RE_PROMPT=true ;;
  esac
done

# ── Step 1: Environment ───────────────────────────────────────────────────────
step "Checking environment"
grep -qi microsoft /proc/version 2>/dev/null && ok "Running inside WSL2" || \
  warn "Not WSL2 — continuing anyway"
ok "Ubuntu $(lsb_release -rs 2>/dev/null || echo unknown)"

# ── Step 2: Install chezmoi ───────────────────────────────────────────────────
step "Checking chezmoi"
export PATH="${HOME}/.local/bin:$PATH"

if command -v chezmoi &>/dev/null; then
  skip "chezmoi $(chezmoi --version 2>/dev/null | head -1)"
else
  ok "Installing chezmoi..."
  mkdir -p "${HOME}/.local/bin"
  if [[ "$DRY_RUN" == false ]]; then
    sh -c "$(curl -fsLS get.chezmoi.io)" -- -b "${HOME}/.local/bin"
    ok "chezmoi installed to ~/.local/bin"
  else
    warn "[dry-run] Would install chezmoi"
  fi
fi

# ── Step 3: Locate source ─────────────────────────────────────────────────────
step "Locating dotfiles source"

CHEZMOI_CONFIG="${HOME}/.config/chezmoi/chezmoi.toml"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -f "${SCRIPT_DIR}/.chezmoi.toml.tmpl" ]]; then
  SOURCE_DIR="$SCRIPT_DIR"
  ok "Running from repo: $SOURCE_DIR"
elif grep -q "sourceDir" "$CHEZMOI_CONFIG" 2>/dev/null; then
  SOURCE_DIR=$(grep "sourceDir" "$CHEZMOI_CONFIG" | sed 's/.*"\(.*\)".*/\1/')
  ok "Configured source: $SOURCE_DIR"
else
  SOURCE_DIR="${HOME}/.local/share/chezmoi"
  if [[ ! -d "$SOURCE_DIR/.git" ]]; then
    ok "Cloning ${GITHUB_ORG}/${REPO}..."
    if [[ "$DRY_RUN" == false ]]; then
      chezmoi init "git@github.com:${GITHUB_ORG}/${REPO}.git"
      ok "Cloned to $SOURCE_DIR"
    else
      warn "[dry-run] Would clone git@github.com:${GITHUB_ORG}/${REPO}.git"
    fi
  else
    skip "Source already at $SOURCE_DIR"
  fi
fi

# ── Step 4: Gather/cache chezmoi data ─────────────────────────────────────────
step "Configuring chezmoi"
mkdir -p "${HOME}/.config/chezmoi"

# Detect what's already cached
has() { grep -q "$1" "$CHEZMOI_CONFIG" 2>/dev/null; }

if [[ "$RE_PROMPT" == true ]]; then
  warn "--re-prompt: clearing cached answers"
  [[ "$DRY_RUN" == false ]] && rm -f "$CHEZMOI_CONFIG"
fi

if has "context" && has "name" && has "email" && has "githubUser" && ! [[ "$RE_PROMPT" == true ]]; then
  skip "chezmoi data already cached"
  # Ensure sourceDir is present
  if ! has "sourceDir" && [[ "$DRY_RUN" == false ]]; then
    sed -i "1s|^|sourceDir = \"${SOURCE_DIR}\"\n\n|" "$CHEZMOI_CONFIG"
    ok "sourceDir added to config"
  fi
else
  if [[ "$DRY_RUN" == true ]]; then
    warn "[dry-run] Would prompt: context, name, email, githubUser"
  else
    echo ""
    echo -e "${CYAN}    Machine context — choose one:${NC}"
    echo -e "${GRAY}      1) personal   2) work${NC}"
    read -r -p "    Choice [1/2]: " CTX_CHOICE
    [[ "$CTX_CHOICE" == "2" ]] && CONTEXT="work" || CONTEXT="personal"

    read -r -p "    Your full name: " USER_NAME
    read -r -p "    Your email address: " USER_EMAIL
    read -r -p "    Your GitHub username: " GITHUB_USER

    cat > "$CHEZMOI_CONFIG" << TOMLEOF
sourceDir = "${SOURCE_DIR}"

[data]
  context    = "${CONTEXT}"
  name       = "${USER_NAME}"
  email      = "${USER_EMAIL}"
  githubUser = "${GITHUB_USER}"
TOMLEOF
    ok "chezmoi config written"
  fi
fi

# ── Step 5: Pull latest (--update) ────────────────────────────────────────────
if [[ "$DO_UPDATE" == true && -d "${SOURCE_DIR}/.git" ]]; then
  step "Pulling latest from GitHub"
  if [[ "$DRY_RUN" == false ]]; then
    git -C "$SOURCE_DIR" pull --ff-only && ok "Pulled latest" || \
      warn "Git pull failed — using existing state"
  else
    warn "[dry-run] Would run: git pull in $SOURCE_DIR"
  fi
fi

# ── Step 6: Diff + Apply ──────────────────────────────────────────────────────
step "Applying dotfiles"

if [[ "$DRY_RUN" == true ]]; then
  warn "Dry run — diff only:"
  chezmoi diff 2>/dev/null || warn "No diff available"
  warn "Run without --dry-run to apply"
else
  DIFF=$(chezmoi diff 2>/dev/null || true)
  if [[ -z "$DIFF" ]]; then
    skip "All dotfiles already up to date"
  else
    echo "$DIFF"
    echo ""
    read -r -p "  Apply these changes? [Y/n]: " APPLY_CHOICE
    if [[ "$APPLY_CHOICE" =~ ^[Nn]$ ]]; then
      warn "Skipped — run 'chezmoi apply' manually when ready"
    else
      chezmoi apply --verbose && ok "Dotfiles applied"
    fi
  fi
fi

# ── Step 7: zsh plugins ───────────────────────────────────────────────────────
step "Installing zsh plugins"
ZSH_DIR="${HOME}/.zsh"; mkdir -p "$ZSH_DIR"

install_plugin() {
  local name="$1" url="$2" dir="${ZSH_DIR}/$3"
  if [[ -d "${dir}/.git" ]]; then
    if [[ "$DO_UPDATE" == true && "$DRY_RUN" == false ]]; then
      git -C "$dir" pull --ff-only -q && ok "$name updated" || skip "$name up to date"
    else
      skip "$name already installed"
    fi
  else
    ok "Installing $name..."
    [[ "$DRY_RUN" == false ]] && git clone --depth=1 "$url" "$dir" -q && ok "$name installed" || \
      warn "[dry-run] Would clone $name"
  fi
}

install_plugin "zsh-autosuggestions"    "https://github.com/zsh-users/zsh-autosuggestions"    "zsh-autosuggestions"
install_plugin "zsh-syntax-highlighting" "https://github.com/zsh-users/zsh-syntax-highlighting" "zsh-syntax-highlighting"

# ── Step 8: PATH note ────────────────────────────────────────────────────────
# ~/.local/bin is managed in dot_zshrc.tmpl — no manual addition needed

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}  ════════════════════════════════════════════${NC}"
echo -e "${CYAN}   Dotfiles ready${NC}"
echo -e "${CYAN}  ════════════════════════════════════════════${NC}"
echo ""

if [[ -f "$CHEZMOI_CONFIG" ]]; then
  CTX=$(grep 'context' "$CHEZMOI_CONFIG" 2>/dev/null | sed 's/.*"\(.*\)".*/\1/' || echo unknown)
  NM=$(grep '  name' "$CHEZMOI_CONFIG" 2>/dev/null | sed 's/.*"\(.*\)".*/\1/' || echo unknown)
  echo -e "  Context : ${CTX}"
  echo -e "  Name    : ${NM}"
  echo -e "  Source  : ${SOURCE_DIR}"
  echo ""
fi

echo -e "  Daily commands:"
echo -e "    chezmoi diff                   # preview pending changes"
echo -e "    chezmoi apply                  # apply changes"
echo -e "    chezmoi edit ~/.zshrc          # edit a managed file"
echo -e "    bash install.sh --update       # pull latest + re-apply"
echo -e "    bash install.sh --re-prompt    # change context/name/email"
echo ""
echo -e "${GRAY}  Source: ${SOURCE_DIR}${NC}"
echo ""
