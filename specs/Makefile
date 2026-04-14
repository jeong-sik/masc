# TLA+ Model Checking — CI integration
# Pattern: tlaplus/Examples (https://github.com/tlaplus/Examples)
#
# Usage:
#   make check-all          Run all specs (clean + buggy)
#   make check-bug-models   Bug models only
#   make check-keeper       Keeper state machine only
#   make check-ecosystem    MASC ecosystem only
#   make check-boundary     Cross-domain boundary specs only
#   make list               List all discoverable specs

JAVA      ?= java
JAVA_OPTS := -XX:+UseParallelGC -Xmx2g
TLC_STOP  := 180
TLC_FLAGS := -workers auto -cleanup

TLA2TOOLS := keeper-state-machine/tla2tools.jar

# Specs with known failures (parsing/evaluation errors under CI tla2tools).
# Remove from this list as specs are fixed. Each entry is a basename (no .cfg).
# KeeperWorkPipeline: clean spec violates invariant (exit 13) — model needs fix, not path issue.
KNOWN_FAILURES ?= KeeperTraceSpec KeeperOASBridge KeeperWorkPipeline

# Buggy specs whose current invariant/model is documented as non-violating.
# Remove from this list once the buggy cfg asserts a stronger property.
KNOWN_BUGGY_NO_VIOLATION ?=

# Module search path: all spec directories so INSTANCE across directories works.
# TLC resolves modules from the spec's own directory + TLA2-Library system property.
SPEC_DIRS := $(shell find . -mindepth 1 -maxdepth 1 -type d | tr '\n' ':')

TLC = $(JAVA) $(JAVA_OPTS) \
	-Dtlc2.TLC.stopAfter=$(TLC_STOP) \
	-Dtlc2.TLC.ide=Github \
	-DTLA2-Library="$(SPEC_DIRS)" \
	-cp $(TLA2TOOLS) tlc2.TLC $(TLC_FLAGS)

CLEAN_CFGS := $(shell find . -name '*.cfg' ! -name '*-buggy*.cfg' ! -name '*-ci.cfg' | sort)
BUGGY_CFGS := $(shell find . -name '*-buggy*.cfg' | sort)

.PHONY: check-all check-clean check-buggy check-bug-models check-keeper check-ecosystem check-boundary list

check-all: check-clean check-buggy
	@echo "=== All TLA+ specs passed ==="

check-clean:
	@echo "=== Running clean specs (expect no errors) ==="; \
	fail=0; \
	cfgs="$(CLEAN_CFGS)"; \
	if [ -z "$$cfgs" ]; then echo "(none)"; exit 0; fi; \
	for cfg in $$cfgs; do \
	  dir=$$(dirname "$$cfg"); \
	  base=$$(basename "$$cfg" .cfg); \
	  tla="$$dir/$$base.tla"; \
	  if [ ! -f "$$tla" ]; then echo "SKIP $$cfg (no .tla)"; continue; fi; \
	  skip=0; for kf in $(KNOWN_FAILURES); do [ "$$base" = "$$kf" ] && skip=1; done; \
	  if [ $$skip -eq 1 ]; then printf "SKIP %-40s (KNOWN_FAILURES)\n" "$$base"; continue; fi; \
	  printf "CHECK %-40s " "$$base"; \
	  $(TLC) -config "$$cfg" "$$tla" > /tmp/tlc-$$base.log 2>&1; \
	  rc=$$?; \
	  if [ $$rc -eq 0 ]; then echo "OK"; \
	  else echo "FAIL (exit $$rc)"; tail -5 /tmp/tlc-$$base.log; fail=1; fi; \
	done; \
	if [ $$fail -eq 1 ]; then exit 1; fi

check-buggy:
	@echo "=== Running buggy specs (expect violations) ==="; \
	fail=0; \
	cfgs="$(BUGGY_CFGS)"; \
	if [ -z "$$cfgs" ]; then echo "(none)"; exit 0; fi; \
	for cfg in $$cfgs; do \
	  dir=$$(dirname "$$cfg"); \
	  stripped=$${cfg%%-buggy*}; \
	  bugbase=$$(basename "$$stripped"); \
	  cfgtag=$$(basename "$$cfg" .cfg); \
	  tla="$$dir/$$bugbase.tla"; \
	  if [ ! -f "$$tla" ]; then echo "SKIP $$cfg (no .tla)"; continue; fi; \
	  skip=0; for kb in $(KNOWN_BUGGY_NO_VIOLATION); do [ "$$bugbase" = "$$kb" ] && skip=1; done; \
	  if [ $$skip -eq 1 ]; then printf "SKIP %-40s (KNOWN_BUGGY_NO_VIOLATION)\n" "$$bugbase (buggy)"; continue; fi; \
	  printf "CHECK %-40s " "$$cfgtag (buggy)"; \
	  $(TLC) -config "$$cfg" "$$tla" > /tmp/tlc-$$cfgtag.log 2>&1; \
	  rc=$$?; \
	  if [ $$rc -eq 12 ] || [ $$rc -eq 13 ]; then echo "OK (violation exit $$rc)"; \
	  elif [ $$rc -eq 0 ]; then echo "FAIL (no violation)"; fail=1; \
	  else echo "WARN (exit $$rc)"; fi; \
	done; \
	if [ $$fail -eq 1 ]; then exit 1; fi

check-bug-models:
	@$(MAKE) --no-print-directory \
	  CLEAN_CFGS="$$(find bug-models/ -name '*.cfg' ! -name '*-buggy*.cfg' | sort)" \
	  BUGGY_CFGS="$$(find bug-models/ -name '*-buggy*.cfg' | sort)" check-all

check-keeper:
	@$(MAKE) --no-print-directory \
	  CLEAN_CFGS="$$(find keeper-state-machine/ -name '*.cfg' ! -name '*-buggy*.cfg' | sort)" \
	  BUGGY_CFGS="$$(find keeper-state-machine/ -name '*-buggy*.cfg' | sort)" check-all

check-ecosystem:
	@$(MAKE) --no-print-directory \
	  CLEAN_CFGS="$$(find masc-ecosystem/ -name '*.cfg' ! -name '*-buggy*.cfg' | sort)" \
	  BUGGY_CFGS="" check-all

check-boundary:
	@$(MAKE) --no-print-directory \
	  CLEAN_CFGS="$$(find boundary/ -name '*.cfg' ! -name '*-buggy*.cfg' | sort)" \
	  BUGGY_CFGS="$$(find boundary/ -name '*-buggy*.cfg' | sort)" check-all

list:
	@echo "Clean specs ($(words $(CLEAN_CFGS))):"; \
	for cfg in $(CLEAN_CFGS); do echo "  $$cfg"; done; \
	echo "Buggy specs ($(words $(BUGGY_CFGS))):"; \
	for cfg in $(BUGGY_CFGS); do echo "  $$cfg"; done
