# POST-INSTALL.md
# Optional Enhancements for Your WSL2 Dev Environment

These are quality-of-life improvements beyond the baseline setup.
None are required — but each one compounds. Do them in order if you're doing all of them,
since Nerd Font unlocks the best Starship preset and the Rust tools unlock the aliases
already wired in your `.zshrc`.

---

## 1. Nerd Font — unlock Starship icons

Without a Nerd Font your Starship prompt uses plain Unicode symbols. With one it uses
language logos, folder icons, and git symbols that render crisply.

**Install on Windows (not in WSL):**

1. Go to [nerdfonts.com/font-downloads](https://www.nerdfonts.com/font-downloads)
   or the [GitHub releases page](https://github.com/ryanoasis/nerd-fonts/releases/latest)
2. Download one of these (recommended):
   - **JetBrainsMono** — clean, no ligatures, highly readable
   - **FiraCode** — has programming ligatures (`!=` → `≠`, `->` → `→`)
   - **CascadiaCode** — Microsoft's font, familiar if you use VS Code defaults
3. Unzip and install the `.ttf` files on Windows (right-click all .ttf or .otf files → Install for all users)
4. Set the font in your terminal:

   **Windows Terminal** — Settings → Profiles → Defaults → Appearance → Font face
   ```
   FiraCode Nerd Font
   ```

   **VS Code integrated terminal** — `settings.json`:
   ```json
   "terminal.integrated.fontFamily": "FiraCode Nerd Font Mono"
   ```

5. Apply the Nerd Font Starship preset:
   ```bash
    # Back up your current config first
    cp ~/.config/starship/starship.toml ~/.config/starship/starship.toml.bak

    # Apply the nerd-font preset (this overwrites the file)
    starship preset nerd-font-symbols -o ~/.config/starship/starship.toml
   ```
   Then edit `~/.config/starship/starship.toml` to restore your `scan_timeout = 10`
   and any other customizations (the preset overwrites the file).

   Naively appending with `cat >>` produces duplicate section headers (the preset
   already defines `[directory]`, `[git_branch]`, etc.) and puts the bare
   `scan_timeout` key after a `[table]`, which is a TOML syntax error.

   Use the bundled merge script instead — it deep-merges overrides into the
   existing sections (no duplicate headers) and keeps `scan_timeout` above the
   tables where TOML requires it. Requires Python 3.11+ (for stdlib `tomllib`):

   ```bash
   python3 ~/dotfiles/scripts/merge-starship-overrides.py
   ```

   Edit [scripts/merge-starship-overrides.py](scripts/merge-starship-overrides.py)
   to change which keys get merged.

   Then reload:

   ```bash
    source ~/.zshrc
   ```

---

## 2. Rust CLI replacements

These replace standard Unix tools with faster, smarter modern versions.
Your `.zshrc` aliases are already wired — install the tools and the aliases activate.

Install all at once:
```bash
sudo apt-get install -y ripgrep fd-find bat
```

> Note: on Ubuntu, `fd` is packaged as `fdfind` and `bat` may be `batcat`.
> The aliases below handle this.

Install `eza` (not in apt on Ubuntu 24.04 — use the official repo):
```bash
sudo apt-get install -y gpg
sudo mkdir -p /etc/apt/keyrings
wget -qO- https://raw.githubusercontent.com/eza-community/eza/main/deb.asc \
  | sudo gpg --dearmor -o /etc/apt/keyrings/gierens.gpg
echo "deb [signed-by=/etc/apt/keyrings/gierens.gpg] http://deb.gierens.de stable main" \
  | sudo tee /etc/apt/sources.list.d/gierens.list
sudo apt-get update && sudo apt-get install -y eza
```

Install `zoxide`:
```bash
curl -sS https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh | bash
```

Install `fzf` (fuzzy finder — powers `Ctrl+R` history search and `Ctrl+T` file picker once wired up):
```bash
sudo apt-get install -y fzf
```

Then enable the keybindings and completion in `~/.zshrc` (Ubuntu's package ships them under `/usr/share/doc/fzf/examples/`):
```zsh
# fzf — fuzzy finder integration
[ -f /usr/share/doc/fzf/examples/key-bindings.zsh ] && source /usr/share/doc/fzf/examples/key-bindings.zsh
[ -f /usr/share/doc/fzf/examples/completion.zsh ]   && source /usr/share/doc/fzf/examples/completion.zsh
```

Manage through chezmoi so it persists:
```bash
chezmoi edit ~/.zshrc
# paste the two source lines above near the bottom, save, then:
chezmoi apply
cd ~/dotfiles && git add dot_zshrc.tmpl && git commit -m "feat: fzf keybindings + completion"
git push
```

After reloading (`source ~/.zshrc`), you get:
- `Ctrl+R` — fuzzy search shell history
- `Ctrl+T` — fuzzy file picker (insert path into command line)
- `Alt+C` — fuzzy `cd` into a subdirectory
- `**<TAB>` — fuzzy completion for paths/processes (e.g. `kill **<TAB>`)

**Add Ubuntu-specific alias fixes to `~/.zshrc`** (needed because of Ubuntu's naming):
```bash
# Ubuntu renames some tools — normalize them
command -v fdfind &>/dev/null && alias fd='fdfind'
command -v batcat &>/dev/null && alias bat='batcat' && alias cat='batcat --style=plain'
```

Or manage this through chezmoi so it persists across machines:
```bash
chezmoi edit ~/.zshrc
# paste the two `command -v ...` lines above into the aliases section, save, then:
chezmoi apply
cd ~/dotfiles && git add dot_zshrc.tmpl && git commit -m "feat: ubuntu fd/bat alias normalization"
git push
```

**Verify everything works:**
```bash
eza -lah --icons --git ~
bat ~/.zshrc
fd --type f --extension sh ~
rg "starship" ~/.zshrc
z ~   # or just start navigating — zoxide learns over time
fzf --version   # then try Ctrl+R in your shell for fuzzy history search
```

---

## 3. `zsh-completions` — tab completion for 600+ tools

Adds completion definitions for tools zsh doesn't include by default:
`docker`, `kubectl`, `gh`, `cargo`, `pip`, `npm`, and hundreds more.

```bash
git clone --depth=1 https://github.com/zsh-users/zsh-completions \
  ~/.zsh/zsh-completions
```

Add to `~/.zshrc` **before** the other plugins (order matters for completions):
```bash
chezmoi edit ~/.zshrc
```

Add these lines near the top of the plugins section, before autosuggestions:
```zsh
# zsh-completions — must be loaded before compinit
fpath=(~/.zsh/zsh-completions/src $fpath)
autoload -Uz compinit && compinit
```

Then apply and reload:
```bash
chezmoi apply
source ~/.zshrc
```

Test it:
```bash
docker run --<TAB>   # should show flags with descriptions
gh repo <TAB>        # if gh CLI is installed
```

Or manage the plugin via `install.sh` — open `~/dotfiles/install.sh` and add:
```bash
install_plugin "zsh-completions" \
  "https://github.com/zsh-users/zsh-completions" \
  "zsh-completions"
```

Then add the `fpath` line to `dot_zshrc.tmpl` in your dotfiles repo.

---

## 4. Extended history with timestamps

Zsh's `EXTENDED_HISTORY` saves the timestamp and wall-clock duration of every command.
Useful forensically — "what exactly did I run Tuesday?" or "how long did that build take?"

Add to `~/.zshrc` (or via `chezmoi edit`):
```zsh
setopt EXTENDED_HISTORY       # save timestamp + duration per entry
setopt HIST_EXPIRE_DUPS_FIRST # expire duplicates first when history fills
setopt INC_APPEND_HISTORY     # write to history immediately, not on exit
```

View timestamped history:
```bash
fc -li 1        # all history with timestamps
fc -li -20      # last 20 commands with timestamps
history -i | grep docker   # find when you last ran docker commands
```

Manage through dotfiles:
```bash
chezmoi edit ~/.zshrc
# add the setopt lines to the History section
chezmoi apply
cd ~/dotfiles && git add dot_zshrc.tmpl && git commit -m "feat: extended history with timestamps"
git push
```

---

## 5. Starship extras worth knowing

**Show time in prompt** (off by default — add to `starship.toml`):
```toml
[time]
disabled    = false
format      = "[$time]($style) "
time_format = "%H:%M"
style       = "dimmed white"
```

**AWS profile** (useful if you work with AWS CLI):
```toml
[aws]
format    = "[$symbol$profile]($style) "
symbol    = "☁️  "
style     = "bold yellow"
disabled  = false
```

**Kubernetes context** (if you use kubectl):
```toml
[kubernetes]
format   = "[$symbol$context( \($namespace\))]($style) "
disabled = false
```

Edit your config:
```bash
chezmoi edit ~/.config/starship/starship.toml
chezmoi apply
```

---

## Dotfiles workflow reminder

Any change you want to persist across machines:

```bash
chezmoi edit ~/.zshrc                    # edit the managed file
chezmoi apply                            # apply to live system
cd ~/dotfiles                            # go to source repo
git add . && git commit -m "feat: ..."  # commit
git push                                 # push to GitHub
```

New machine picks it up with:
```bash
bash install.sh --update
```
