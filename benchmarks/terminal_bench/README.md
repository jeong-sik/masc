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

## Lane status (2026-09-10, masc v0.35.6)

- `kimi_coding/kimi-for-coding` — docker smoke Succeeded (1 keeper, arm b);
  needs `GH_TOKEN` in the env (keeper_up preflight runs `gh auth status`).
- `anthropic/claude-fable-5` — unblocked in v0.35.6: backend_anthropic now
  projects top-level oneOf/anyOf/allOf out of tool input_schemas at request
  build time (#35168). The bench-side [[one_of]] strip in render_configs.py
  was removed at the same time. Needs re-verification against the release
  binary; use `ANTHROPIC_API_KEY_MASC` (host `ANTHROPIC_API_KEY` is invalid).
- arm spawn/delegate gating uses keeper TOML `tools.deny` (v0.35.6, #35169):
  spawn tools denied when parallel=False (arms b, c, d), delegate tools
  denied when keepers=1 (arms b-e). The earlier skills.names-only gating
  could not hide them.
- `openai/gpt-5.x` — harness reaches the API; the current OPENAI_API_KEY
  project has no credits and lacks gpt-5.5, so this lane is unverified past
  the request-build stage.
