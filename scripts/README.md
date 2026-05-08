#!/usr/bin/env bash
# This directory contains companion setup scripts for WSL2 machines.
# These are run once after cloning dotfiles to provision the environment.
#
# Windows side (PowerShell, run as Admin):
#   .\Setup-WSL2.ps1
#
# Linux side (inside WSL):
#   Personal/home machine:
#     bash scripts/Setup-Home-Ubuntu.sh
#
#   Work/corporate machine:
#     bash scripts/Setup-Work-Ubuntu.sh
#
# After running the appropriate setup script, bootstrap dotfiles with:
#   bash install.sh
