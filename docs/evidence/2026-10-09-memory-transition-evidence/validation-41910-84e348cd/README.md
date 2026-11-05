# #41910 bounded semantic validation

Executed 108 authorized direct TypeSafe calls without retries or instruction/data tuning. Source head: `84e348cd3e321a667edeeeaa4d6ce54c08f0c63c`. The gate source identity/digest and complete request questions are retained in `policy.json`. Policy SHA256: `5b21d8dc48cb3c946c19165679aafbb817ce0b20e9f4c91b7767bcbc028d4413`. All responses report the pinned model `jev-1.13.0`. There were no provider errors or invalid responses.

| Cohort: six cases, three repetitions per arm | Current pair-only | Historical evidence question with empty observations | Current source observations |
|---|---:|---:|---:|
| Retained development | 15/18 | 12/18 | 18/18 |
| Independently frozen new held-out | 18/18 | 15/18 | 18/18 |

No arm incorrectly merged a negative case. The current source-observation arm had no false retention in either cohort. The development stale-lock follow-up was refused in all three pair-only calls and accepted in all three evidence calls. Development restoration and the new catalog closure were refused only by the historical empty-observation control. Per-case typed decisions and scores remain in each cohort JSONL; raw response bytes retain probabilities, confidence and usage.

Three repetitions are not three independent cases. Pair-only already matches all six new cases, so this cohort does not establish an improvement over that baseline.

## Request identity and provenance

Arm A uses the current `Pair_only` instruction and original two-field state. Its 1,370 instruction bytes exactly match the historical frozen pair question. Arm B deliberately uses the prior `8257c108` evidence-aware production question with an empty observations list, which current code no longer selects. Arm C uses the same question as B with observations. These production instructions differ from #41922's earlier experimental suffix; the B/C comparison holds instructions constant.

Development source, candidate, observation text and labels are unchanged. Its synthetic observations are wrapped in the actual conversation-record shape, with synthetic batch references and local positions. They are not represented as verified host outcomes. The independent new cohort already supplied production-shaped records, including a typed unknown tool outcome; those records pass through unchanged. Labels, rationales and expected values never enter provider requests.

Agent `review_roots_a` froze the new cohort at SHA256 `564a53c3a6b0a7f9127a4e9e709c9bc07f1f053cc2f6e9833aa83f057349c5dc` before calls or inspection of new results. The same bytes were verified before and after execution. The author's protocol is retained. The author knew the source contract and excluded development domains: this is not a blinded or representative production evaluation.

The original historical 12-case cohort remains unavailable and was **not reproduced**. Neither cohort proves installed runtime behavior, long-term memory quality or reliable consolidation of all future events.

## Retained evidence and usage

Every request was saved and hashed before its cohort executed. This portable package combines all calls into two JSONL files. Each record binds its cohort case, arm, repetition, timestamps, score and hashes to lossless base64 request/response bytes. Original per-call start markers remain in the local execution archive; the executor enforced a ceiling of 108 started calls and exclusive marker creation to prevent silent reruns. All 108 request/response hash pairs and raw-response base64 round trips were verified. No credentials, HTTP headers or environment values are stored.

Provider usage was 91,134 input and 6,732 output tokens. At the [current official price](https://docs.typesafe.ai/models.md) of $0.042 per million input tokens with free output, estimated cost is **$0.003827628**. This is a list-price estimate, not a billing receipt.

Execution used `/v1/systemone`, pinned `jev-1.13.0`, four workers, a 60-second transport deadline, no sampling parameters and no automatic retries. Source/runtime fixture execution and formal current-head independent review remain separate. No local Dune build or installed Keeper execution occurred.

## Offline verification

Run `python3 verify.py` from this directory. It makes no network calls and verifies frozen case/policy hashes, exact canonical request bytes, cohort membership/order, lossless response hashes, typed Choice decoding, per-case scores, model identity, usage and totals. To additionally verify the source blob in a local checkout, run `python3 verify.py --repo /path/to/masc`.

The verifier accepts the retained package and rejects deliberately corrupted request hashes and stored scores. It verifies internal consistency and source binding, not the truth of synthetic labels or an external provider signature.
