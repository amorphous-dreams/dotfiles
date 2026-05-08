#!/usr/bin/env python3
"""Merge custom overrides into ~/.config/starship/starship.toml.

Run after `starship preset nerd-font-symbols -o ~/.config/starship/starship.toml`
to restore project-specific tweaks without producing duplicate section headers
or putting bare keys after a [table] (a TOML syntax error).

Usage:
    python3 scripts/merge-starship-overrides.py [path]

`path` defaults to ~/.config/starship/starship.toml.
"""
import sys
import tomllib
import pathlib

OVERRIDES_SCALAR = {
    "scan_timeout": 10,
}

OVERRIDES_TABLE = {
    "directory":    {"truncate_to_repo": True, "truncation_length": 2, "truncation_symbol": "…/"},
    "git_branch":   {"truncation_length": 24, "truncation_symbol": "…"},
    "git_status":   {"modified": "!", "staged": "+", "untracked": "?",
                     "ahead": "⇡${count}", "behind": "⇣${count}",
                     "diverged": "⇕⇡${ahead_count}⇣${behind_count}"},
    "cmd_duration": {"min_time": 2000, "style": "yellow"},
}


import re

_BARE_KEY = re.compile(r"^[A-Za-z0-9_-]+$")


def fmt_key(k):
    return k if _BARE_KEY.match(k) else '"' + k.replace("\\", "\\\\").replace('"', '\\"') + '"'


def fmt(v):
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, int):
        return str(v)
    return '"' + str(v).replace("\\", "\\\\").replace('"', '\\"') + '"'


def dump(cfg):
    out = []

    def emit_table(prefix, tbl):
        scalars = {k: v for k, v in tbl.items() if not isinstance(v, dict)}
        subtables = {k: v for k, v in tbl.items() if isinstance(v, dict)}
        if prefix:
            out.append(f"\n[{prefix}]")
        out.extend(f"{fmt_key(k)} = {fmt(v)}" for k, v in scalars.items())
        for name, sub in subtables.items():
            path = f"{prefix}.{fmt_key(name)}" if prefix else fmt_key(name)
            emit_table(path, sub)

    emit_table("", cfg)
    return "\n".join(out) + "\n"


def main():
    path = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else \
        pathlib.Path.home() / ".config/starship/starship.toml"

    cfg = tomllib.loads(path.read_text())
    cfg.update(OVERRIDES_SCALAR)
    for section, values in OVERRIDES_TABLE.items():
        cfg.setdefault(section, {}).update(values)

    path.write_text(dump(cfg))
    print(f"Merged overrides into {path}")


if __name__ == "__main__":
    main()
