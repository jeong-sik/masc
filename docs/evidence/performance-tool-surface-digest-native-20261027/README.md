# Native incremental surface digest: closed comparison

**No service GC gain was demonstrated.** The four 300-owner whole-process health GC snapshot deltas average **50,754,778,832B control** versus **51,052,786,308B candidate**, an observed **+0.587151560617404…%**. Two cohorts per role, shared host, different builders, audit gaps and unequal inventory work establish neither a causal improvement nor a causal regression.

This retains the native follow-up to [the incremental digest source/carrier result](../performance-tool-surface-digest-streaming-20261027/README.md). Candidate application/builder is 6df61978; control application is 8e61fa43 with builder 6a2d8dd. The relevant production/build/config difference is one keeper_tool_load_receipts.ml file. [Provenance](provenance.json), [receipts](native/candidate-receipt.json) and [qualification](native/candidate-qualification.json) keep actual binary identity separate from source, builder and later publication ancestry. Later TUI span code468 is absent from these measured binaries.

## Six fresh, closed workloads

Order was candidate2, candidate30, then control/candidate/candidate/control300. Each owner received two messages; the loopback scripted text fixture delayed each response 10ms after the intentional first-wave hold. Parameters were 15s per-request timeout, 1200s settlement bound and 0.1s live sampling. No profiler, TUI, local benchmark or artifact download overlapped these unprofiled comparison windows.

| Cell | Role / owners | GC snapshot delta B | Operations / calls / peak | Status-read timeouts | HTTP429 | Denied inventory commands |
| --- | --- | ---: | --- | ---: | ---: | ---: |
| Smoke1 | candidate / 2 | 270,154,480 | 4 / 4 / 2 | 0 | 0 | 2 |
| Smoke2 | candidate / 30 | 3,986,534,464 | 60 / 60 / 30 | 0 | 4 | 2 |
| A1 | control / 300 | 50,106,204,736 | 600 / 600 / 300 | 2 | 54 | 672 |
| B1 | candidate / 300 | 51,417,086,312 | 600 / 600 / 300 | 3 | 46 | 1,092 |
| B2 | candidate / 300 | 50,688,486,304 | 600 / 600 / 300 | 1 | 59 | 602 |
| A2 | control / 300 | 51,403,352,928 | 600 / 600 / 300 | 2 | 54 | 675 |

All six actual native commands and six reader-helper commands returned0, with owned children reaped0 and closed logs. Each server exited0 without forced kill, providers drained, and original bases were retained. The next cell began after the previous reader closed. [Selected closure locators](actual-closure-summary.json) identify original actual tool records separately from child receipts. Every legacy be6 attempt here was NOT_ATTEMPTED; the frozen0825 reader was the first actual reader. Old Map-reader failures and results belong to a separate campaign.

All 2,464 original operations and scripted calls were joined through raw public RPCs, exact owner/opid, admission/execution/member digests, typed fixture replies, original owner stores and backups. Held and terminal batch-member counts were zero: there is no native batch-follower proof. Actual requests had stream:true while the retained TOML says streaming=false; configuration does not establish transport behavior.

## Negative observations remain part of the result

All 8,916 MCP attempts include 8,691 HTTP200, 217 HTTP429 and eight approximately15s status-read TimeoutErrors. Each failed read had a later successful read for that same operation; failed attempts remain failures. The four large cells retain 213 HTTP429, with recorded waits 54.328256/46.287847/59.401787/54.307189s. Successful status-read maxima were 7.209/8.895/10.304/6.577s. These success-only distributions are not durable completion times or stable latency acceptance.

All 4,712 retained live-health samples were valid, but maxima reached6.779s. Full-health began warming and remained degraded/addon_unattached, requiring operator action. Nested cached sections could be about26.7s stale. Startup preparation envelopes were2.154–2.552s from the post-Popen receipt to initialize preparation, excluding preceding Popen work; they establish neither state-ready transition nor UI paint. Saved full-health JSON lacks original response-body/header/acquisition-clock receipts.

Large inventory contained two list commands and 670/1090/600/673 denied volume inspections. Complete600-volume coverage was followed by partial known subsets70/490/absent/73, leaving530/110/0/527 unobserved in those final groups. These are observed coverage groups, not producer cycle IDs; missing coverage is not proven missing log records. None is actual daemon/guest execution, and unequal background work was not normalized away.

The GC metric is the whole-program quick_stat snapshot-counter difference of (minor_words + major_words - promoted_words) ×8. Counters may lag collection boundaries and include creation/background work; this is not exact allocation, function-exclusive saving, CPU, RSS or throughput. Cell distributions are retained individually rather than merging percentiles.

## Independent evidence and build boundaries

The retained [raw-data review](reviews/raw-evidence.md.txt) passed with P0/P1/P2=0 after3,696 guarded immutable/query-only SQL connections across2,464 distinct original/backup DBs, all closed. Thirty reader derivatives matched:24 exactly, six after only the exact audit_output address substitution. All85,613 original paths, bytes and captured metadata remained unchanged; all148 selected external inputs were conserved. The actual public reader uses mode=ro; only the independent audit adapter adds immutability and effect guards.

The separate [descriptor/receipt/arithmetic review](reviews/descriptor.md.txt) passed with P0/P1/P2=0. It checked all six rows,150 input hashes, actual root return records, clocks, captured maps and rational arithmetic, without another SQL audit or original packet rescan. [Audit summary](audit-summary.json) and [review scopes](reviews.json) preserve attribution and prior authorship disclosures. These session reviews are not formal GitHub approvals. An initial utility allowlist failure was retained before its source-provenance-only repair and successful final raw audit.

Separate focused typed CI passed44+14+1=59 cases. Native workflow40419664296 remained overallFAIL from inherited retained-diff whitespace; native job121910651163 succeeded on seven selected targets and55 resource cases. Both embedded-source identity children exited0, serverstderr82B/TUI0B. Enclosing qualification session11932 completion remains UNKNOWN. No full regression, primary installation, production deployment, external model, peer/broadcast, real Add-on fleet, visible TUI, loaded-library identity,0.1ms or whole-Goal completion is established.

## Retention and fresh reproduction

[observations.json](observations.json) compactly formats original3da31448… with every decoded value equal. The production diff is a JSON-string derivative that decodes to its exact original text. The other14 selected captures retain exact bytes. [Capture locations](capture-locations.json) preserve original/retained digests and transformations. Historical plan execute:false, qualification scopes and root summary audit-pending wording remain capture-time states; later completed reviews are separate records.

[recorded-capture-hashes.json](recorded-capture-hashes.json) is a newly authored manifest of16 selected staging byte revisions, not an original raw-run manifest. [current-locations.json](current-locations.json) maps them to retained versioned paths. Newly authored summaries/locators are identified as selections. Raw RPC/provider payloads, databases, executables and credentials remain private.

Check retained locations and bytes:

```sh
python3 -B -E scripts/check-evidence-locations.py \
  docs/evidence/performance-tool-surface-digest-native-20261027/current-locations.json
```

The exact historical controller/deriver/helper are .py.txt source captures, with frozen private paths and already completed output leaves. They are not portable reproduction helpers; changing their paths invalidates their qualification. No fresh workload, SQL audit or aggregate was executed by this curation.

For a new experiment, qualify source/binary/builder/fixture identities and freeze a new plan with fresh output leaves before execution. The current [public runner](../../../scripts/harness/perf/keeper_scale_session.py) and [reader](../../../scripts/harness/perf/keeper_scale_packet_audit.py) are byte-identical to the frozen a6df19e9/0825b967 sources. For example, an independently qualified new2-owner smoke uses:

```sh
python3 -B -E scripts/harness/perf/keeper_scale_session.py \
  --binary /absolute/path/to/qualified/masc --repo /absolute/path/to/checkout \
  --output artifacts/runs/FRESH-digest-smoke --keepers 2 --messages-per-keeper 2 \
  --model-delay-ms 10 --request-timeout 15 --settle-timeout 1200 --sample-interval .1
python3 -B -E scripts/harness/perf/keeper_scale_packet_audit.py \
  artifacts/runs/FRESH-digest-smoke --output artifacts/runs/FRESH-external-reader
```

Those commands create a new result and require new actual return, cleanup, conservation and independent audit evidence. They do not reproduce the closed result from this selected archive alone. Never write new output into this retained bundle.
