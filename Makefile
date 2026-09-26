# Makefile for gptel-permit

EMACS ?= emacs
LOAD_PATH_GPTEL ?= ~/repos/emacs/gptel

.PHONY: all clean test

all: test

clean:
	rm -f *.elc tests/*.elc

test: clean
	$(EMACS) -batch -q \
		-L $(LOAD_PATH_GPTEL) \
		-L . \
		-L ./tests \
		-l gptel-permit-test.el \
		-l gptel-permit-tool-groups-test.el \
		-l gptel-permit-rule-engine-test.el \
		-l gptel-permit-rule-engine-hooks-test.el \
		-l gptel-permit-validation-test.el \
		-l gptel-permit-hook-integration-test.el \
		-l gptel-permit-callable-conditions-test.el \
		-l gptel-permit-judge-test.el \
		-l gptel-permit-sandbox-test.el \
		-l gptel-permit-analytics-test.el \
		-f ert-run-tests-batch-and-exit
