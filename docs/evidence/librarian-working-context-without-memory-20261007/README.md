# Working-context pass without current Memory (2026-10-07)

PR #41408. Audit item D3-04 (`docs/audits/2026-10-01-week-audit-findings.md`)
asked for replayed payloads scored with JEV before the variable was cut. This
folder holds the aggregates and the scripts. Reports with Memory and source
text stay outside the repository (`$WC_AB_OUT`).

## Why this pass

Recorded Librarian runs, 2026-10-06 16:11 – 10-07 01:23 KST (9.2 h):

| pass | runs | prompt | of which current_memory |
|---|---|---|---|
| Memory (`librarian`) | 681 | 168 MB | 144 MB |
| continuity | 296 | 51 MB | 45 MB |
| working context | 954 | 216 MB | 200 MB |

The working-context pass never judges or writes Memory. Its template told the
model to use `current_memory` "for reference only".

## Method (`ab.py`)

- Sample: recorded working-context passes that committed and had at least two
  sources, up to three per Keeper, spread over time.
- Each sample is sent twice to the Librarian lane's model
  (`deepseek-v4.1-flash` on Ollama Cloud), one request at a time:
  - once from the recorded template and variables, which reproduce the
    production prompt byte for byte (50/50 checked);
  - once with `current_memory` replaced by a sentence saying it is not
    included.
- Recorded production answers serve as the run-to-run baseline.

## Source grouping (`compare.py`)

| | round 1 | round 2 |
|---|---|---|
| samples | 30 | 30 (new sample) |
| with Memory = recorded production | 27 | 29 |
| without Memory = with Memory | 28 | 30 |
| merged contexts and completeness also equal | 28 | 30 |
| input tokens, median (with → without) | 78,338 → 5,794 | 75,555 → 6,140 |

Round 1's two differing cases also differed between the recorded answer and
the with-Memory rerun.

## Context and next-step text

**JEV pairwise (`jev_pairwise.py`, round 2)**

- JEV sees the sources, the Keeper instructions and the two answers in random
  X/Y order, and picks the better one or `equivalent`.
- The second row compares two answers that both had Memory, so it measures
  the judge and run-to-run noise.

| pair | first better | second better | equivalent | not measured |
|---|---|---|---|---|
| without Memory vs with Memory | 13 | 11 | 4 | 2 |
| recorded vs with Memory (noise) | 12 | 9 | 7 | 2 |

The two unmeasured samples are one Keeper whose sources made the JEV request
134 KB and 222 KB, which JEV refused as `max_tokens_exceeded`.

**Identifier check (round 1)**

- No with-Memory answer cited an identifier (post, comment, PR, task) that
  exists only in Memory and is missing from the without-Memory answer (0 of
  23 samples whose payloads were still on disk).
- The two Keepers with the largest Memory (431 KB, 426 KB) were also read
  side by side, and their contexts carried the same facts.

## Reproduce

```sh
export WC_AB_OUT=/path/outside/the/repo
OLLAMA_CLOUD_API_KEY=… python3 -I ab.py 30
TYPESAFEAI_API_KEY=… python3 -I jev_pairwise.py
python3 -I compare.py
```

`ab.py` reads `~/me/.masc/exact-lane-run-payloads`, which keeps only the
latest ~2,000 runs.
