# Makefile for gptel-permit

EMACS ?= emacs
LOAD_PATH_GPTEL ?= ~/repos/emacs/gptel

# The package split: one repo, four packages.  Each entry is
# PACKAGE-DIR:FILES (space separated, relative to the repo root),
# mirroring what each MELPA recipe's :files directive selects.
PACKAGE_CORE     = gptel-permit            gptel-permit.el
PACKAGE_JUDGE    = gptel-permit-judge      gptel-permit-judge.el
PACKAGE_SANDBOX  = gptel-permit-sandbox    gptel-permit-sandbox.el gptel-permit-sandbox-bwrap.el gptel-permit-sandbox-srt.el
PACKAGE_ANALYTIC = gptel-permit-analytics  gptel-permit-analytics.el
PACKAGES         = $(PACKAGE_CORE) $(PACKAGE_JUDGE) $(PACKAGE_SANDBOX) $(PACKAGE_ANALYTIC)

.PHONY: all clean test package-build $(PACKAGES)

all: test

clean:
	rm -rf build *.elc tests/*.elc

test: clean
	$(EMACS) -batch -q \
		-L $(LOAD_PATH_GPTEL) \
		-L . \
		-L ./tests \
		-l gptel-permit-test.el \
		-l gptel-permit-tool-groups-test.el \
		-l gptel-permit-rule-engine-test.el \
		-l gptel-permit-rule-engine-hooks-test.el \
		-l gptel-permit-rule-scopes-test.el \
		-l gptel-permit-validation-test.el \
		-l gptel-permit-hook-integration-test.el \
		-l gptel-permit-callable-conditions-test.el \
		-l gptel-permit-judge-test.el \
		-l gptel-permit-judge-action-test.el \
		-l gptel-permit-sandbox-test.el \
		-l gptel-permit-analytics-test.el \
		-f ert-run-tests-batch-and-exit

# Stage each package's :files into build/<pkg>/ exactly as package.el
# would install it, then byte-compile the core standalone and every
# module against ONLY the staged core (plus gptel).  This is the
# decidable check for the split's invariant: no module may reference a
# symbol its staged dependency set does not provide (e.g. analytics
# calling a sandbox function).  A fresh-install failure surfaces here,
# not in a user's Emacs.
#
# Subset smoke runs (4.3): in any fresh directory holding just the
# subset's files, e.g. core-only tests:
#  emacs -batch -q -L $(LOAD_PATH_GPTEL) -L . -L ./tests \
#   -l tests/gptel-permit-test.el ...-l tests/gptel-permit-callable-conditions-test.el \
#   -f ert-run-tests-batch-and-exit      ; 155 core tests
# core+sandbox/-judge/-analytics: add the respective file(s) and -l its
# test suite; each subset must load and run without the others.
package-build: $(PACKAGES)
	@echo "All four packages staged and compiled against their dependency closure."

# Optional: package-lint each staged package (MELPA-level checks).
# Requires package-lint on the load path; skips silently if missing.
# The gptel-permit dependency cannot resolve in a lint run (it is not
# on any archive yet), so seed `package-archive-contents' with a stub
# entry for it before linting; expect, and ignore, one "not
# installable" line per module if this fails, plus the prefix errors
# for core-owned cross-module state (gptel-permit--last-judge-*,
# --sandbox--rewritten-args) which are the documented ABI declares.
LINT_DIR ?= ~/.emacs.d/elpa/package-lint-20260903.2119

package-lint:
	@for pkg in gptel-permit gptel-permit-judge gptel-permit-sandbox gptel-permit-analytics; do \
	  for f in build/$$pkg/*.el; do \
	    test -f $$f || continue; \
	    echo "== lint $$f"; \
	    $(EMACS) -batch -q -L $(LINT_DIR) -L $(LOAD_PATH_GPTEL) -L build/gptel-permit \
	      -l package-lint \
	      --eval "(require 'package)" \
	      --eval "(setq package-archive-contents \
	                   (cons (cons 'gptel-permit \
	                               '((1 . [(0 1 0) nil nil nil \"0.1.0\"]))) \
	                         package-archive-contents))" \
	      -f package-lint-batch-and-exit $$f 2>&1 || true; \
	  done; \
	done

gptel-permit:
	@mkdir -p build/$@
	cp -f $(word 2,$(PACKAGE_CORE)) build/$@/
	$(EMACS) -batch -q -L $(LOAD_PATH_GPTEL) -L build/$@ \
		-f batch-byte-compile build/$@/*.el

gptel-permit-judge gptel-permit-sandbox gptel-permit-analytics:
	@mkdir -p build/$@/build/gptel-permit
	cp -f $(PACKAGE_FILES) build/$@/
	cp -f $(word 2,$(PACKAGE_CORE)) build/$@/build/gptel-permit/
	$(EMACS) -batch -q -L $(LOAD_PATH_GPTEL) \
		-L build/$@/build/gptel-permit -L build/$@ \
		-f batch-byte-compile build/$@/*.el

gptel-permit-judge:      PACKAGE_FILES = $(wordlist 2,999,$(PACKAGE_JUDGE))
gptel-permit-sandbox:    PACKAGE_FILES = $(wordlist 2,999,$(PACKAGE_SANDBOX))
gptel-permit-analytics:  PACKAGE_FILES = $(wordlist 2,999,$(PACKAGE_ANALYTIC))
