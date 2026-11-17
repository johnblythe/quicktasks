# Quicktasks dev targets. Nothing here installs, launches, or restarts anything.
.PHONY: build test test-quiet
.DEFAULT_GOAL := test

build:
	menubar/build.sh --no-install

# Everything, including test_menubar_model.py, whose seams (--snapshot,
# --dump-layout, --dump-summon, ...) put panels on screen.
test:
	python3 -m unittest discover -s tests

# Skips test_menubar_*.py so nothing draws on screen. Use this during focus work.
test-quiet:
	python3 -m unittest discover -s tests -p 'test_[!m]*.py'

test-%:
	python3 -m unittest discover -s tests -p 'test_$*.py'
