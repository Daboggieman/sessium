# sessium bash completion — source this or install to
# /etc/bash_completion.d/sessium (or ~/.local/share/bash-completion/completions/sessium)

_sessium() {
    local cur prev commands
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"
    commands="list status check setup push pull sync diff resolve revert open search log version help"

    # complete the command word
    if [ "$COMP_CWORD" -eq 1 ]; then
        COMPREPLY=( $(compgen -W "$commands" -- "$cur") )
        return 0
    fi

    local sub
    sub="${COMP_WORDS[1]}"

    case "$prev" in
        --project)
            # munged project folder names (start with '-'; disable filename matching)
            local dirs
            dirs=$(ls -1 "${SESSIUM_CLAUDE_DIR:-$HOME/.claude}/projects" 2>/dev/null)
            while read -r d; do
                COMPREPLY+=( "--project=$d" )
            done <<< "$dirs"
            return 0
            ;;
    esac

    case "$sub" in
        list)
            COMPREPLY=( $(compgen -W "--titles --project --json --debug" -- "$cur") )
            ;;
        status)
            COMPREPLY=( $(compgen -W "--project --json --debug" -- "$cur") )
            ;;
        setup|check|version)
            COMPREPLY=( $(compgen -W "--check-only --debug" -- "$cur") )
            ;;
        push|pull)
            COMPREPLY=( $(compgen -W "--project --dry-run --debug" -- "$cur") )
            ;;
        sync)
            COMPREPLY=( $(compgen -W "--project --interactive --dry-run --debug" -- "$cur") )
            ;;
        diff|resolve|revert|open)
            # session id prefixes: complete from local transcript files
            local ids
            ids=$(ls -1 "${SESSIUM_CLAUDE_DIR:-$HOME/.claude}/projects"/*/*.jsonl 2>/dev/null \
                  | xargs -rn1 basename 2>/dev/null | sed 's/\.jsonl$//')
            COMPREPLY=( $(compgen -W "$ids" -- "$cur") )
            ;;
        adopt)
            # first arg: munged folder; second: any path (no completion)
            if [ "$COMP_CWORD" -eq 2 ]; then
                local dirs
                dirs=$(ls -1 "${SESSIUM_CLAUDE_DIR:-$HOME/.claude}/projects" 2>/dev/null)
                COMPREPLY=( $(compgen -W "$dirs" -- "$cur") )
            fi
            ;;
        search)
            COMPREPLY=( $(compgen -W "--project --limit --semantic --json --debug" -- "$cur") )
            ;;
        log)
            COMPREPLY=( $(compgen -W "--titles --project --json --debug" -- "$cur") )
            ;;
    esac
    return 0
}
complete -F _sessium sessium
