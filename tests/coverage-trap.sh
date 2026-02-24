#!/usr/bin/env bash
# coverage-trap.sh — BASH_ENV xtrace enabler for lightweight code coverage
#
# Sourced automatically by every bash child process via BASH_ENV.
# Uses BASH_XTRACEFD (Bash 4.1+) to redirect xtrace output through a
# grep filter that keeps only lines from our source files.
#
# Each bash process opens its own FD + grep filter because FDs set with
# exec {fd}> get the close-on-exec flag and don't survive exec().
# Multiple grep filters append to the same hits.log safely via
# --line-buffered (atomic writes under PIPE_BUF).
#
# Requires: _MPS_COV_DIR environment variable set to output directory.

# Guard: skip if coverage not requested
[[ -z "${_MPS_COV_DIR:-}" ]] && return 0

# Resolve tool paths once (some tests use restricted PATHs without grep/mkdir)
_cov_grep=$(command -v grep 2>/dev/null) || return 0
_cov_mkdir=$(command -v mkdir 2>/dev/null) || return 0

# Set xtrace prefix to include source file and line number
PS4='+ ${BASH_SOURCE[0]:-}:${LINENO}: '

# Every bash process needs its own FD + grep filter pipe.
# The grep pattern matches paths under /workdir for: bin/mps, lib/, commands/,
# completions/, install.sh, uninstall.sh
"$_cov_mkdir" -p "$_MPS_COV_DIR" 2>/dev/null || return 0
# Xtrace nests: + for top-level, ++ for one level deep, etc.
# Match one or more '+' followed by space and our source paths.
exec {BASH_XTRACEFD}> >("$_cov_grep" --line-buffered -E '^\++ /workdir/(bin/mps|lib/|commands/|completions/|install\.sh|uninstall\.sh)' \
    >> "$_MPS_COV_DIR/hits.log" 2>/dev/null)

set -x
