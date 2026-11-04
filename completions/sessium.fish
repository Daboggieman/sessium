# sessium fish completion — install to ~/.config/fish/completions/sessium.fish

complete -c sessium -f

set -l commands list status check setup push pull sync diff resolve revert open search log version

# command names
complete -c sessium -n "not __fish_seen_subcommand_from $commands" -a "list"  -d "browse sessions, newest first"
complete -c sessium -n "not __fish_seen_subcommand_from $commands" -a "status" -d "classify every session vs ledger vs Drive"
complete -c sessium -n "not __fish_seen_subcommand_from $commands" -a "check"  -d "connectivity + config + ledger self-test"
complete -c sessium -n "not __fish_seen_subcommand_from $commands" -a "setup"  -d "run the rclone/Drive setup script"
complete -c sessium -n "not __fish_seen_subcommand_from $commands" -a "push"   -d "upload new/changed sessions"
complete -c sessium -n "not __fish_seen_subcommand_from $commands" -a "pull"   -d "download new/changed sessions"
complete -c sessium -n "not __fish_seen_subcommand_from $commands" -a "sync"   -d "push AND pull; decides conflicts"
complete -c sessium -n "not __fish_seen_subcommand_from $commands" -a "diff"   -d "local vs remote vs last-synced"
complete -c sessium -n "not __fish_seen_subcommand_from $commands" -a "resolve" -d "decide a conflicted session by hand"
complete -c sessium -n "not __fish_seen_subcommand_from $commands" -a "revert" -d "swap a kept revert copy back in"
complete -c sessium -n "not __fish_seen_subcommand_from $commands" -a "open"   -d "print the resume command for a session"
complete -c sessium -n "not __fish_seen_subcommand_from $commands" -a "search" -d "search sessions"
complete -c sessium -n "not __fish_seen_subcommand_from $commands" -a "log"    -d "alias for list"
complete -c sessium -n "not __fish_seen_subcommand_from $commands" -a "version" -d "print the version"

# flags per command
complete -c sessium -n "__fish_seen_subcommand_from list log"    -l titles  -d "show session titles"
complete -c sessium -n "__fish_seen_subcommand_from status list log push pull sync diff" -l project -x -a "(command ls ~/.claude/projects)" -d "restrict to one project"
complete -c sessium -n "__fish_seen_subcommand_from list status diff search" -l json -d "machine-readable output"
complete -c sessium -n "__fish_seen_subcommand_from push pull sync revert adopt" -l dry-run -d "print actions, change nothing"
complete -c sessium -n "__fish_seen_subcommand_from sync resolve" -l interactive -d "force the conflict prompt"
complete -c sessium -n "__fish_seen_subcommand_from setup" -l check-only -d "verify without prompts"
complete -c sessium -n "__fish_seen_subcommand_from search" -l limit -x -d "max results"
complete -c sessium -n "__fish_seen_subcommand_from search" -l semantic -d "use the seeker engine when configured"
complete -c sessium -s d -l debug -d "print every rclone call"

# session id prefixes for id-taking commands
complete -c sessium -n "__fish_seen_subcommand_from diff resolve revert open" -a "(command ls ~/.claude/projects/*/*.jsonl | string replace -r '.*/' '' | string replace -r '.jsonl\$' '')"
