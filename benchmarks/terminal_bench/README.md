# MASC × Terminal-Bench 2.0 (Harbor)

MASC 하네스 자체를 벤치마크한다. 스펙: docs/superpowers/specs/2026-09-09-masc-harness-benchmark-design.md

## Setup

    ./image/fetch_masc.sh          # prebuilt masc 바이너리
    uv venv && uv pip install harbor pytest
    export ANTHROPIC_API_KEY=...   # 또는 BENCH_API_KEY_ENV가 가리키는 키

## Smoke (1 task, arm B)

    source .venv/bin/activate
    harbor run -d terminal-bench@2.0 -i gpt2-codegolf \
      --agent agents.masc_agent:MascAgent -m anthropic/claude-fable-5 \
      --ak arm=b -k 1 -n 1 -o results/jobs

## Mini-suite matrix

    ./run_matrix.sh                # arms a,b,c,e,f,h × suite × k=3
    python aggregate.py            # results/jobs → results/summary.csv

## Lane status (2026-09-10, masc v0.35.2)

- `kimi_coding/kimi-for-coding` — docker smoke Succeeded (1 keeper, arm b);
  needs `GH_TOKEN` in the env (keeper_up preflight runs `gh auth status`).
- `anthropic/claude-fable-5` — BLOCKED upstream: every keeper turn 400s with
  `input_schema does not support oneOf at the top level`. The tool_execute
  schema is embedded in the release binary (lib/embedded_config, ocaml-crunch
  over config/ at build time) and backend_anthropic has no conformant-schema
  projection (only backend_openai_serialize.ml strips top-level combinators).
  Not fixable from bench config; needs a masc release with the anthropic
  projection.
- `openai/gpt-5.x` — harness reaches the API; the current OPENAI_API_KEY
  project has no credits and lacks gpt-5.5, so this lane is unverified past
  the request-build stage.
