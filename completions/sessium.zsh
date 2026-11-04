#compdef sessium
# sessium zsh completion — drop in your fpath (e.g. ~/.zfunc/sessium)

_sessium() {
    local -a commands
    commands=(
        'list:browse sessions, newest first'
        'status:classify every session vs ledger vs Drive'
        'check:connectivity + config + ledger self-test'
        'setup:run the rclone/Drive setup script'
        'push:upload new/changed sessions (skips conflicts)'
        'pull:download new/changed sessions (skips conflicts)'
        'sync:push AND pull; decides conflicts'
        'diff:local vs remote vs last-synced, side by side'
        'resolve:decide a conflicted session by hand'
        'revert:swap a kept revert copy back in'
        'open:print the resume command for a session'
        'search:search sessions (literal, or semantic via seeker)'
        'log:alias for list'
        'version:print the version'
    )
    _arguments -C \
        '1:command:->cmd' \
        '(--titles)--titles[show session titles]' \
        '(--project)--project=[restrict to one munged project]:project:_path_files -W "$HOME/.claude/projects" -g "*(/)"' \
        '(--json)--json[machine-readable output]' \
        '(--dry-run)--dry-run[print actions, change nothing]' \
        '(--interactive)--interactive[force the conflict prompt]' \
        '(--check-only)--check-only[setup: verify without prompts]' \
        '(--limit)--limit=[max results (search)]:N:' \
        '(--semantic)--semantic[use the seeker engine when configured]' \
        '(--debug)--debug[print every rclone call]' \
        '*:session id:->ids'
    case "$state" in
        cmd)
            _describe 'command' commands
            ;;
        ids)
            local -a files ids
            files=($HOME/.claude/projects/*/*.jsonl(N))
            ids=(${files[@]##*/})
            ids=(${ids[@]%.jsonl})
            _describe -t ids 'session id' ids
            ;;
    esac
}
_sessium "$@"
