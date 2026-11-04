# sessium developer entry points

.PHONY: test lint install man completions check clean

test:            ## run the hermetic test suite (34 tests, fake rclone)
	python3 tests/run_tests.py

lint:            ## ruff over the Linux CLI (stdlib-only project, no deps needed)
	ruff check linux/sessium || echo "(ruff not installed — skip)"

install:         ## install the CLI + man page + completions for this user
	bash install.sh

man:             ## preview the man page
	man docs/sessium.1

completions:     ## print install hints for the three shells
	@echo "bash: source completions/sessium.bash   (or copy to ~/.local/share/bash-completion/completions/sessium)"
	@echo "zsh:  copy completions/sessium.zsh   to a dir on your fpath (e.g. ~/.zfunc/sessium)"
	@echo "fish: copy completions/sessium.fish  to ~/.config/fish/completions/"

check: test      ## alias for test

clean:           ## remove test/__pycache__ scratch
	rm -rf tests/__pycache__ tests/lib/__pycache__
