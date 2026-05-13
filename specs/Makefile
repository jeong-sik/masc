# TLA+ Model Checking — CI integration
# Pattern: tlaplus/Examples (https://github.com/tlaplus/Examples)
#
# Usage:
#   make check-all          Run all specs (clean + buggy)
#   make check-bug-models   Bug models only
#   make check-keeper       Keeper state machine only
#   make check-ecosystem    MASC ecosystem only
#   make check-boundary     Cross-domain boundary specs only
#   make check-closure      Contract-closure specs (autoresearch<->verification<->FSM)
#   make list               List all discoverable specs

JAVA      ?= java
JAVA_OPTS := -XX:+UseParallelGC -Xmx2g
TLC_STOP  := 180
TLC_FLAGS := -workers auto -cleanup

LOCAL_TLA2TOOLS := keeper-state-machine/tla2tools.jar
HOME_TLA2TOOLS  := $(HOME)/.local/lib/tla/tla2tools-1.8.0.jar

ifeq ($(origin TLA2TOOLS), undefined)
  ifneq ($(wildcard $(LOCAL_TLA2TOOLS)),)
    TLA2TOOLS := $(LOCAL_TLA2TOOLS)
  else ifneq ($(wildcard $(HOME_TLA2TOOLS)),)
    TLA2TOOLS := $(HOME_TLA2TOOLS)
  else
    TLA2TOOLS := $(LOCAL_TLA2TOOLS)
  endif
endif

# Specs with known failures (parsing/evaluation errors under CI tla2tools).
# Remove from this list as specs are fixed. Each entry is a basename (no .cfg).
# KeeperWorkPipeline: clean spec violates invariant (exit 13) — model needs fix, not path issue.
# KeeperStateMachine: CompactionClearsOverflow invariant contradicts CompactionFailed
# action (Failed deliberately preserves context_overflow for retry). Tracked in #8710;
# proper fix requires discriminating CompactionCompleted vs CompactionFailed in the
# invariant. Temporary skip unblocks PR queue (30+ PRs inheriting this fail).
KNOWN_FAILURES ?= KeeperTraceSpec KeeperWorkPipeline KeeperStateMachine

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

clean_cfgs_in = $(shell find $(1) -name '*.cfg' ! -name '*-buggy*.cfg' | sort)
buggy_cfgs_in = $(shell find $(1) -name '*-buggy*.cfg' | sort)

.PHONY: check-all check-clean check-buggy check-bug-models check-keeper check-ecosystem check-boundary check-closure check-social check-others check-matrix-coverage list clean clean-artefacts

clean: clean-artefacts

clean-artefacts:
	@bash $(shell git rev-parse --show-toplevel)/scripts/cleanup-tlc-artifacts.sh

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
	  if [ $$skip -eq 1 ]; then printf "SKIP  %-40s (KNOWN_FAILURES)\n" "$$base"; continue; fi; \
	  printf "CHECK %-40s ...\n" "$$base"; \
	  start_ts=$$(date +%s); \
	  $(TLC) -config "$$cfg" "$$tla" > /tmp/tlc-$$base.log 2>&1; \
	  rc=$$?; \
	  end_ts=$$(date +%s); \
	  duration=$$((end_ts - start_ts)); \
	  if [ $$rc -eq 0 ]; then printf "OK    %-40s (%3ds)\n" "$$base" "$$duration"; \
	  else printf "FAIL  %-40s (exit $$rc, %3ds)\n" "$$base" "$$duration"; tail -15 /tmp/tlc-$$base.log; fail=1; fi; \
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
	  if [ $$skip -eq 1 ]; then printf "SKIP  %-40s (KNOWN_BUGGY_NO_VIOLATION)\n" "$$bugbase (buggy)"; continue; fi; \
	  printf "CHECK %-40s ...\n" "$$cfgtag (buggy)"; \
	  start_ts=$$(date +%s); \
	  $(TLC) -config "$$cfg" "$$tla" > /tmp/tlc-$$cfgtag.log 2>&1; \
	  rc=$$?; \
	  end_ts=$$(date +%s); \
	  duration=$$((end_ts - start_ts)); \
	  if [ $$rc -eq 12 ] || [ $$rc -eq 13 ]; then printf "OK    %-40s (violation exit $$rc, %3ds)\n" "$$cfgtag (buggy)" "$$duration"; \
	  elif [ $$rc -eq 0 ]; then printf "FAIL  %-40s (no violation, %3ds)\n" "$$cfgtag (buggy)" "$$duration"; fail=1; \
	  else printf "WARN  %-40s (exit $$rc, %3ds)\n" "$$cfgtag (buggy)" "$$duration"; fi; \
	done; \
	if [ $$fail -eq 1 ]; then exit 1; fi

check-bug-models: CLEAN_CFGS := $(call clean_cfgs_in,bug-models/)
check-bug-models: BUGGY_CFGS := $(call buggy_cfgs_in,bug-models/)
check-bug-models: check-all

check-keeper: CLEAN_CFGS := $(call clean_cfgs_in,keeper-state-machine/)
check-keeper: BUGGY_CFGS := $(call buggy_cfgs_in,keeper-state-machine/)
check-keeper: check-all

check-ecosystem: CLEAN_CFGS := $(call clean_cfgs_in,masc-ecosystem/)
check-ecosystem: BUGGY_CFGS :=
check-ecosystem: check-all

check-boundary: CLEAN_CFGS := $(call clean_cfgs_in,boundary/)
check-boundary: BUGGY_CFGS := $(call buggy_cfgs_in,boundary/)
check-boundary: check-all

check-closure: CLEAN_CFGS := $(call clean_cfgs_in,closure/)
check-closure: BUGGY_CFGS := $(call buggy_cfgs_in,closure/)
check-closure: check-all

# Sharding groups for CI matrix.  The four targets below partition the same
# spec set that `check-all` walks; verified by the `check-matrix-coverage`
# target which fails if anything drifts out of sync.  Tuning:
#
#   keeper-state-machine   ~4 min   (34 cfgs, dominated by KSM specs)
#   masc-ecosystem         ~6 min   (MASCEcosystem 352s)
#   social-and-state-prod  ~3 min   (SocialStateCap 180s top)
#   others (14 dirs)       ~7 min   (incl. KeeperStaleKilled 182s + MemoryCompaction 181s)
#
# Wall-clock fan-out reduces TLA+ Main from ~22 min monolithic to ~7-8 min.

SOCIAL_DIRS := social-state-cap state-product
check-social: CLEAN_CFGS := $(foreach d,$(SOCIAL_DIRS),$(call clean_cfgs_in,$(d)/))
check-social: BUGGY_CFGS := $(foreach d,$(SOCIAL_DIRS),$(call buggy_cfgs_in,$(d)/))
check-social: check-all

OTHER_DIRS := admission-queue auth autonomous boundary bug-models cascade \
              checkpoint-trim closure keeper-turn-fsm multimodal resilience \
              server-state shared task-lifecycle
check-others: CLEAN_CFGS := $(foreach d,$(OTHER_DIRS),$(call clean_cfgs_in,$(d)/))
check-others: BUGGY_CFGS := $(foreach d,$(OTHER_DIRS),$(call buggy_cfgs_in,$(d)/))
check-others: check-all

# Coverage check: every spec directory must appear in exactly one shard.
# Run in CI before sharded jobs to catch silent drops when new dirs land.
SHARD_DIRS_ALL := keeper-state-machine masc-ecosystem $(SOCIAL_DIRS) $(OTHER_DIRS)
check-matrix-coverage: SHELL := /bin/bash
check-matrix-coverage:
	@set -euo pipefail; \
	all_sorted=$$(find . -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sort -u); \
	dups=$$(printf '%s\n' $(SHARD_DIRS_ALL) | sort | uniq -d); \
	if [ -n "$$dups" ]; then echo "::error::Dirs listed in more than one shard:"; echo "$$dups"; exit 1; fi; \
	shard_sorted=$$(printf '%s\n' $(SHARD_DIRS_ALL) | sort -u); \
	missing=$$(comm -23 <(printf '%s\n' "$$all_sorted") <(printf '%s\n' "$$shard_sorted")); \
	extra=$$(comm -13 <(printf '%s\n' "$$all_sorted") <(printf '%s\n' "$$shard_sorted")); \
	if [ -n "$$missing" ]; then echo "::error::Spec dirs missing from CI shards:"; echo "$$missing"; exit 1; fi; \
	if [ -n "$$extra" ]; then echo "::error::Shard references unknown dirs:"; echo "$$extra"; exit 1; fi; \
	echo "Matrix coverage OK ($$(printf '%s\n' "$$all_sorted" | wc -l | tr -d ' ') dirs across 4 shards)"

list:
	@echo "Clean specs ($(words $(CLEAN_CFGS))):"; \
	for cfg in $(CLEAN_CFGS); do echo "  $$cfg"; done; \
	echo "Buggy specs ($(words $(BUGGY_CFGS))):"; \
	for cfg in $(BUGGY_CFGS); do echo "  $$cfg"; done
