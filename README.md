# dotfiles

Managed by [chezmoi](https://chezmoi.io). Works on personal and work WSL2 Ubuntu machines.

---

## Quick start

### New machine

```bash
# 1. Run the appropriate WSL2 setup script first (from PowerShell on Windows)
.\Setup-WSL2.ps1

# 2. Run the appropriate Ubuntu setup script (from inside WSL)
bash scripts/Setup-Home-Ubuntu.sh    # personal machine
bash scripts/Setup-Work-Ubuntu.sh    # work/corporate machine

# 3. Bootstrap dotfiles
bash install.sh
```

`install.sh` will:
- Install chezmoi
- Clone this repo to `~/.local/share/chezmoi`
- Prompt you once for context, name, email, and GitHub username
- Apply all dotfiles
- Install zsh-autosuggestions and zsh-syntax-highlighting

### Already have chezmoi + this repo cloned

```bash
chezmoi update        # pull latest changes + re-apply
```

---

## What's managed

| File | Notes |
|---|---|
| `~/.zshrc` | nvm, SSH agent, aliases, plugins, Starship |
| `~/.bashrc` | nvm, SSH agent, Starship (bash fallback) |
| `~/.gitconfig` | identity, aliases, context-specific settings |
| `~/.ssh/config` | GitHub + context-specific hosts |
| `~/.config/starship/starship.toml` | prompt config, same on all machines |

---

## Contexts

On first run you choose a context. This is cached and never re-prompted.

| Context | DNS | Windows PATH | Git URL rewrite |
|---|---|---|---|
| `personal` | WSL auto-managed | available | SSH over HTTPS |
| `work` | manual (VPN DNS) | excluded | — |

To re-answer prompts on an existing machine:
```bash
chezmoi init --force && chezmoi apply
```

---

## Daily workflow

```bash
# Edit a managed file
chezmoi edit ~/.zshrc

# Preview changes before applying
chezmoi diff

# Apply changes
chezmoi apply

# Pull latest from GitHub + apply
chezmoi update

# See current chezmoi data (name, email, context, etc.)
chezmoi data
```

---

## Adding a new file to management

```bash
chezmoi add ~/.config/some/config
chezmoi edit ~/.config/some/config
chezmoi apply
chezmoi cd    # opens a shell in the source directory
git add . && git commit -m "add some/config" && git push
```

---

## Companion scripts

| Script | Purpose |
|---|---|
| `scripts/Setup-WSL2.ps1` | Windows side — features, WSL install, distro, networking |
| `scripts/Setup-Home-Ubuntu.sh` | Linux side — personal machine provisioning |
| `scripts/Setup-Work-Ubuntu.sh` | Linux side — work/corporate machine provisioning |

---

## Structure

```
dotfiles/
├── .chezmoi.toml.tmpl          # machine prompts (context, name, email, githubUser)
├── install.sh                  # idempotent bootstrap script
├── README.md
├── dot_zshrc.tmpl              # → ~/.zshrc
├── dot_bashrc.tmpl             # → ~/.bashrc
├── dot_gitconfig.tmpl          # → ~/.gitconfig
├── dot_config/
│   └── starship/
│       └── starship.toml       # → ~/.config/starship/starship.toml
├── dot_ssh/
│   └── config.tmpl             # → ~/.ssh/config
└── scripts/
    ├── Setup-WSL2.ps1
    ├── Setup-Home-Ubuntu.sh
    └── Setup-Work-Ubuntu.sh
```
