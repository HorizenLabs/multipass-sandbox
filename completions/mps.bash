#!/usr/bin/env bash
# mps(1) bash completion — delegates to `mps __complete`
# Bash 3.2+ compatible. Do NOT use set -euo pipefail.

# Guard: only load if `complete` builtin is available
command -v complete &>/dev/null || return 0

_mps_completions() {
    local cur prev cword
    # Use _init_completion if available (bash-completion ≥2.0), else manual init
    if declare -F _init_completion &>/dev/null; then
        _init_completion || return
    else
        cur="${COMP_WORDS[COMP_CWORD]}"
        prev="${COMP_WORDS[COMP_CWORD-1]}"
        cword=$COMP_CWORD
    fi

    # Find command word (first non-flag argument after "mps")
    local cmd="" subcmd="" i past_separator=false
    for (( i=1; i < cword; i++ )); do
        local w="${COMP_WORDS[i]}"
        if [[ "$w" == "--" ]]; then
            past_separator=true
            break
        fi
        # Skip flags and their values
        case "$w" in
            --debug|--help|-h|--version|-v) continue ;;
        esac
        if [[ -z "$cmd" ]]; then
            cmd="$w"
        elif [[ -z "$subcmd" ]]; then
            # Only set subcmd for commands that have subcommands
            case "$cmd" in
                image|mount|port)
                    case "$w" in
                        -*) ;; # flag, not subcommand
                        *)  subcmd="$w" ;;
                    esac
                    ;;
            esac
        fi
    done

    # Past "--" separator: default file completion
    if [[ "$past_separator" == "true" ]]; then
        COMPREPLY=()
        return
    fi

    local raw_words=""

    if [[ -z "$cmd" ]]; then
        # Complete command names + global flags
        raw_words="$(mps __complete commands 2>/dev/null)"
        raw_words="${raw_words} --help --version --debug"
    elif [[ -z "$subcmd" ]]; then
        # Check if previous word is a flag that takes a value
        case "$prev" in
            --name|-n|--image|--cpus|--memory|--mem|--disk|--cloud-init|--profile|--mount|--port|--transfer|--ssh-key|--workdir|-w|--arch|--tag)
                raw_words="$(mps __complete "$cmd" flag-values "$prev" 2>/dev/null)"
                ;;
            *)
                # Check if this command has subcommands
                local subcmds=""
                subcmds="$(mps __complete "$cmd" subcmds 2>/dev/null)"
                if [[ -n "$subcmds" ]]; then
                    raw_words="${subcmds} $(mps __complete "$cmd" flags 2>/dev/null)"
                else
                    raw_words="$(mps __complete "$cmd" flags 2>/dev/null)"
                fi
                ;;
        esac
    else
        # Have subcommand — complete subcommand flags or flag values
        case "$prev" in
            --name|-n|--arch|--tag)
                raw_words="$(mps __complete "$cmd" flag-values "$prev" 2>/dev/null)"
                ;;
            *)
                raw_words="$(mps __complete "$cmd" "$subcmd" flags 2>/dev/null)"
                ;;
        esac
    fi

    # Resolve magic tokens
    local resolved=""
    local word
    for word in $raw_words; do
        case "$word" in
            __instances__)
                local inst
                inst="$(mps __complete instances 2>/dev/null)"
                resolved="${resolved} ${inst}"
                ;;
            __profiles__)
                local prof
                prof="$(mps __complete profiles 2>/dev/null)"
                resolved="${resolved} ${prof}"
                ;;
            __images__)
                local imgs
                imgs="$(mps __complete images 2>/dev/null)"
                resolved="${resolved} ${imgs}"
                ;;
            __cloud_init__)
                local ci
                ci="$(mps __complete cloud_init 2>/dev/null)"
                resolved="${resolved} ${ci}"
                ;;
            __archs__)
                resolved="${resolved} amd64 arm64"
                ;;
            __files__)
                # Use compgen for file completion
                while IFS='' read -r comp; do
                    COMPREPLY+=("$comp")
                done < <(compgen -f -- "$cur")
                return
                ;;
            *)
                resolved="${resolved} ${word}"
                ;;
        esac
    done

    while IFS='' read -r comp; do
        COMPREPLY+=("$comp")
    done < <(compgen -W "$resolved" -- "$cur")
}

complete -o default -F _mps_completions mps
