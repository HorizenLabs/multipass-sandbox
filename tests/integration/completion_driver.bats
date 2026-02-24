#!/usr/bin/env bats
# Integration tests for _mps_completions() — the bash completion driver
# in completions/mps.bash. Sources the driver in-process, stubs `mps` as a
# bash function (shadows the binary), simulates tab completions via
# COMP_WORDS / COMP_CWORD, and asserts on COMPREPLY contents.

load ../test_helper

# ================================================================
# Stub: mps() function — handles __complete queries deterministically
# ================================================================

mps() {
    [[ "${1:-}" == "__complete" ]] || return 1
    shift
    local action="${1:-}"
    shift 2>/dev/null || true

    case "$action" in
        commands)
            printf '%s\n' create up down destroy shell exec list status \
                ssh-config image mount port transfer
            ;;
        instances) printf '%s\n' my-vm other-vm ;;
        profiles)  printf '%s\n' micro lite standard heavy ;;
        images)    printf '%s\n' base protocol-dev ;;
        cloud_init) printf '%s\n' default custom ;;
        create|up)
            case "${1:-}" in
                subcmds) ;;
                flags) echo "--name -n --image --cpus --memory --mem --disk --cloud-init --profile --mount --port --transfer --no-mount --help -h" ;;
                flag-values)
                    case "${2:-}" in
                        --name|-n)    echo "__instances__" ;;
                        --profile)    echo "__profiles__" ;;
                        --image)      echo "__images__" ;;
                        --cloud-init) echo "__cloud_init__" ;;
                    esac
                    ;;
            esac
            ;;
        down|destroy)
            case "${1:-}" in
                subcmds) ;;
                flags) echo "--name -n --force -f --help -h" ;;
                flag-values)
                    case "${2:-}" in --name|-n) echo "__instances__" ;; esac
                    ;;
            esac
            ;;
        shell|exec)
            case "${1:-}" in
                subcmds) ;;
                flags) echo "--name -n --workdir -w --help -h" ;;
                flag-values)
                    case "${2:-}" in --name|-n) echo "__instances__" ;; esac
                    ;;
            esac
            ;;
        list)
            case "${1:-}" in
                subcmds) ;;
                flags) echo "--json --help -h" ;;
            esac
            ;;
        status)
            case "${1:-}" in
                subcmds) ;;
                flags) echo "--name -n --json --help -h" ;;
                flag-values)
                    case "${2:-}" in --name|-n) echo "__instances__" ;; esac
                    ;;
            esac
            ;;
        ssh-config)
            case "${1:-}" in
                subcmds) ;;
                flags) echo "--name -n --ssh-key --print --append --help -h" ;;
                flag-values)
                    case "${2:-}" in
                        --name|-n) echo "__instances__" ;;
                        --ssh-key)  echo "__files__" ;;
                    esac
                    ;;
            esac
            ;;
        transfer)
            case "${1:-}" in
                subcmds) ;;
                flags) echo "--name -n --help -h" ;;
                flag-values)
                    case "${2:-}" in --name|-n) echo "__instances__" ;; esac
                    ;;
            esac
            ;;
        image)
            case "${1:-}" in
                subcmds)    echo "list pull import remove" ;;
                flags)      echo "--help -h" ;;
                flag-values)
                    case "${2:-}" in
                        --arch) echo "__archs__" ;;
                        --name) echo "__images__" ;;
                    esac
                    ;;
                list|pull|import|remove)
                    local sub="${1:-}"
                    shift 2>/dev/null || true
                    case "${1:-}" in
                        flags)
                            case "$sub" in
                                list)   echo "--remote --help -h" ;;
                                pull)   echo "--force -f --help -h" ;;
                                import) echo "--name --tag --arch --help -h" ;;
                                remove) echo "--arch --all --force -f --help -h" ;;
                            esac
                            ;;
                    esac
                    ;;
            esac
            ;;
        mount)
            case "${1:-}" in
                subcmds)    echo "add remove list" ;;
                flags)      echo "--help -h" ;;
                flag-values)
                    case "${2:-}" in --name|-n) echo "__instances__" ;; esac
                    ;;
                add|remove|list)
                    local sub="${1:-}"
                    shift 2>/dev/null || true
                    case "${1:-}" in
                        flags) echo "--name -n --help -h" ;;
                    esac
                    ;;
            esac
            ;;
        port)
            case "${1:-}" in
                subcmds) echo "forward list" ;;
                flags)   echo "--help -h" ;;
                forward|list)
                    local sub="${1:-}"
                    shift 2>/dev/null || true
                    case "${1:-}" in
                        flags)
                            case "$sub" in
                                forward) echo "--privileged --help -h" ;;
                                list)    echo "--help -h" ;;
                            esac
                            ;;
                    esac
                    ;;
            esac
            ;;
    esac
    return 0
}

# ================================================================
# Source the completion driver (defines _mps_completions)
# ================================================================

# shellcheck source=../../completions/mps.bash
source "${MPS_ROOT}/completions/mps.bash"

# ================================================================
# Helpers
# ================================================================

# Simulate tab completion at the given cursor position.
# Usage: _complete_at "mps" "create" "--name" ""
# The last argument is the word being completed (cur).
_complete_at() {
    COMP_WORDS=("$@")
    COMP_CWORD=$(( ${#COMP_WORDS[@]} - 1 ))
    COMPREPLY=()
    _mps_completions
}

# Assert word is present in COMPREPLY
_reply_has() {
    local word="$1"
    local joined
    joined=" $(printf '%s ' ${COMPREPLY[@]+"${COMPREPLY[@]}"}) "
    if [[ "$joined" != *" $word "* ]]; then
        printf 'Expected COMPREPLY to contain "%s"\nCOMPREPLY=(%s)\n' \
            "$word" "${COMPREPLY[*]-}" >&2
        return 1
    fi
}

# Assert word is NOT present in COMPREPLY
_reply_lacks() {
    local word="$1"
    local joined
    joined=" $(printf '%s ' ${COMPREPLY[@]+"${COMPREPLY[@]}"}) "
    if [[ "$joined" == *" $word "* ]]; then
        printf 'Expected COMPREPLY to NOT contain "%s"\nCOMPREPLY=(%s)\n' \
            "$word" "${COMPREPLY[*]-}" >&2
        return 1
    fi
}

# Assert COMPREPLY is empty
_reply_is_empty() {
    if [[ ${#COMPREPLY[@]} -ne 0 ]]; then
        printf 'Expected empty COMPREPLY, got %d entries\nCOMPREPLY=(%s)\n' \
            "${#COMPREPLY[@]}" "${COMPREPLY[*]-}" >&2
        return 1
    fi
}

# ================================================================
# A. Top-level completion (no command yet)
# ================================================================

@test "top-level: empty word completes commands and global flags" {
    _complete_at "mps" ""
    _reply_has "create"
    _reply_has "image"
    _reply_has "--help"
    _reply_has "--version"
    _reply_has "--debug"
}

@test "top-level: prefix 'cr' filters to create" {
    _complete_at "mps" "cr"
    _reply_has "create"
    _reply_lacks "destroy"
    _reply_lacks "image"
}

@test "top-level: prefix '--' filters to global flags only" {
    _complete_at "mps" "--"
    _reply_has "--help"
    _reply_has "--version"
    _reply_has "--debug"
    _reply_lacks "create"
}

# ================================================================
# B. Global flag skipping
# ================================================================

@test "global-flag: --debug skipped, still completing commands" {
    _complete_at "mps" "--debug" ""
    _reply_has "create"
    _reply_has "destroy"
}

@test "global-flag: --debug before command, command flags shown" {
    _complete_at "mps" "--debug" "create" ""
    _reply_has "--name"
    _reply_has "--profile"
}

@test "global-flag: --help treated as global flag, still completing commands" {
    _complete_at "mps" "--help" ""
    _reply_has "create"
    _reply_has "image"
}

# ================================================================
# C. Command flag completion
# ================================================================

@test "cmd-flags: create shows all flags" {
    _complete_at "mps" "create" ""
    _reply_has "--name"
    _reply_has "--profile"
    _reply_has "--image"
    _reply_has "--help"
}

@test "cmd-flags: list shows --json and --help" {
    _complete_at "mps" "list" ""
    _reply_has "--json"
    _reply_has "--help"
}

@test "cmd-flags: create with '--' prefix shows only long flags" {
    _complete_at "mps" "create" "--"
    _reply_has "--name"
    _reply_has "--help"
    _reply_lacks "-n"
    _reply_lacks "-h"
}

@test "cmd-flags: down shows --name and --force" {
    _complete_at "mps" "down" ""
    _reply_has "--name"
    _reply_has "--force"
    _reply_has "-f"
}

# ================================================================
# D. Flag-value completion
# ================================================================

@test "flag-value: create --name resolves to instances" {
    _complete_at "mps" "create" "--name" ""
    _reply_has "my-vm"
    _reply_has "other-vm"
}

@test "flag-value: create -n resolves to instances (short alias)" {
    _complete_at "mps" "create" "-n" ""
    _reply_has "my-vm"
    _reply_has "other-vm"
}

@test "flag-value: create --profile resolves to profiles" {
    _complete_at "mps" "create" "--profile" ""
    _reply_has "micro"
    _reply_has "lite"
    _reply_has "standard"
    _reply_has "heavy"
}

@test "flag-value: create --image resolves to images" {
    _complete_at "mps" "create" "--image" ""
    _reply_has "base"
    _reply_has "protocol-dev"
}

@test "flag-value: create --cloud-init resolves to cloud_init templates" {
    _complete_at "mps" "create" "--cloud-init" ""
    _reply_has "default"
    _reply_has "custom"
}

@test "flag-value: create --name with prefix 'my' filters matches" {
    _complete_at "mps" "create" "--name" "my"
    _reply_has "my-vm"
    _reply_lacks "other-vm"
}

@test "flag-value: create --profile with prefix 'li' filters matches" {
    _complete_at "mps" "create" "--profile" "li"
    _reply_has "lite"
    _reply_lacks "micro"
    _reply_lacks "standard"
}

# ================================================================
# E. Subcommand completion
# ================================================================

@test "subcmd: image shows subcommands and flags" {
    _complete_at "mps" "image" ""
    _reply_has "list"
    _reply_has "pull"
    _reply_has "import"
    _reply_has "remove"
    _reply_has "--help"
}

@test "subcmd: image with prefix 'li' filters to list" {
    _complete_at "mps" "image" "li"
    _reply_has "list"
    _reply_lacks "pull"
    _reply_lacks "remove"
}

@test "subcmd: mount shows subcommands" {
    _complete_at "mps" "mount" ""
    _reply_has "add"
    _reply_has "remove"
    _reply_has "list"
}

@test "subcmd: port shows subcommands" {
    _complete_at "mps" "port" ""
    _reply_has "forward"
    _reply_has "list"
}

@test "subcmd: image with '--' prefix filters to flags only" {
    _complete_at "mps" "image" "--"
    _reply_has "--help"
    _reply_lacks "list"
    _reply_lacks "pull"
}

# ================================================================
# F. Subcommand flag and flag-value completion
# ================================================================

@test "subcmd-flags: image pull shows --force and --help" {
    _complete_at "mps" "image" "pull" ""
    _reply_has "--force"
    _reply_has "-f"
    _reply_has "--help"
}

@test "subcmd-flag-value: image import --arch resolves to architectures" {
    _complete_at "mps" "image" "import" "--arch" ""
    _reply_has "amd64"
    _reply_has "arm64"
}

@test "subcmd-flag-value: image import --name resolves to images" {
    _complete_at "mps" "image" "import" "--name" ""
    _reply_has "base"
    _reply_has "protocol-dev"
}

@test "subcmd-flag-value: mount add --name resolves to instances" {
    _complete_at "mps" "mount" "add" "--name" ""
    _reply_has "my-vm"
    _reply_has "other-vm"
}

@test "subcmd-flags: port forward shows --privileged and --help" {
    _complete_at "mps" "port" "forward" ""
    _reply_has "--privileged"
    _reply_has "--help"
}

# ================================================================
# G. Separator handling (--)
# ================================================================

@test "separator: exec -- stops completion" {
    _complete_at "mps" "exec" "--" ""
    _reply_is_empty
}

@test "separator: exec --name foo -- cmd stops completion" {
    _complete_at "mps" "exec" "--name" "foo" "--" "cmd" ""
    _reply_is_empty
}

# ================================================================
# H. File completion (__files__)
# ================================================================

@test "file-completion: ssh-config --ssh-key triggers compgen -f" {
    _complete_at "mps" "ssh-config" "--ssh-key" ""
    # __files__ token triggers compgen -f and early return;
    # verify no instance/profile tokens leaked through
    _reply_lacks "my-vm"
    _reply_lacks "micro"
}

# ================================================================
# I. Edge cases
# ================================================================

@test "edge: unknown command returns empty completion" {
    _complete_at "mps" "nonexistent" ""
    _reply_is_empty
}

@test "edge: extra positional after command still shows flags" {
    _complete_at "mps" "create" "foo" ""
    _reply_has "--name"
    _reply_has "--help"
}

@test "edge: flag-like word not set as subcmd for image" {
    _complete_at "mps" "image" "-f" ""
    # -f is treated as a flag, not a subcmd; driver still offers subcmds+flags
    _reply_has "list"
    _reply_has "pull"
    _reply_has "--help"
}

@test "edge: multiple flag-value pairs complete correctly" {
    _complete_at "mps" "create" "--name" "my-vm" "--profile" ""
    _reply_has "micro"
    _reply_has "lite"
    _reply_has "standard"
    _reply_has "heavy"
}

# ================================================================
# J. _init_completion path
# ================================================================

@test "init-completion: uses _init_completion when available" {
    # Define _init_completion that mimics bash-completion behavior
    # shellcheck disable=SC2034  # cur/prev/cword consumed by _mps_completions
    _init_completion() {
        cur="${COMP_WORDS[COMP_CWORD]}"
        prev="${COMP_WORDS[COMP_CWORD-1]}"
        cword=$COMP_CWORD
        return 0
    }
    _complete_at "mps" "create" ""
    _reply_has "--name"
    _reply_has "--profile"
    unset -f _init_completion
}

# ================================================================
# K. Guard and registration
# ================================================================

@test "registration: complete -p mps shows _mps_completions" {
    local reg
    reg="$(complete -p mps 2>&1)"
    [[ "$reg" == *"_mps_completions"* ]]
    [[ "$reg" == *"-o default"* ]]
}
