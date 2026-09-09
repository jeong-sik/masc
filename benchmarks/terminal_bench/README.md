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
