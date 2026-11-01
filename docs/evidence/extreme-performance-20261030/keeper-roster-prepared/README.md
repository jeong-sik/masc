# Source-owned prepared roster candidate

The product candidate prepares a name lookup once with each fetched roster and
stores the original observation and lookup as one opaque immutable value. It
does not rebuild indexes for all side inputs on every list preparation, the
[rejected design](../keeper-projection-rejected/README.md). The 100 us full
performance goal remains open. Actual product build, focused product-test
execution and native TUI timing are unverified at this capture boundary.

## Product ownership and behavior

`roster_of_reading` builds the view and name index together. `roster_view` exposes
the original values; `liveness_of_roster` keeps its original call signature and
reads the index. First observed rows and first errors win separately, and errors
override rows of the same name. A missing name in a partial or unobserved roster
remains unobserved. A complete roster still confirms absence. There is no new
mutable state field, worker pool, refresh setting, timeout or wire contract.

The existing loader prepares the value inside `Masc_tui_response_decode.run`,
which calls `Domain_pool_ref.submit_cpu_or_inline`. This can run inline under
the existing pool policy; it does not guarantee another CPU domain. Existing
workspace/ticket and `Snapshot_read` admission control application. Accepted
roster failure and confirmed workspace resets withdraw view and index together.
The existing identity-unconfirmed path may preserve both for display while
authority is suspended; the index grants no new authority. The module does not
embed a workspace lease or enforce caller freshness by itself.

The `/queue resume` retained-input guard also calls this loader and then looks
up one name. It therefore pays cold preparation even for one lookup. This path
is preserved and remains a measured-cost concern, not a claimed universal win.
Three focused product tests were added for duplicate live/stopped rows, first
error overriding a present row, and independent partial/unobserved replacement
values withdrawing lifecycle choices. The third tests values, not real UI state
replacement, workspace admission or a late HTTP result. Product test execution
is not established by parsing or the excerpt checks below.

## Prototype timing and memory

The prototype uses reduced runtime records, not the product packet decoder or
entire TUI. Each case has five batches in one process; medians summarize
per-operation batch averages, not individual latency quantiles. A batch lookup
operation reads all N existing names of a complete roster in roster order.
`first` means the roster's first name, repeatedly queried after a warmup; it
does not mean the first call after construction. Failure/partial/missing-name
timing and production query distributions are not covered.

| N | Source constructor us | Constructor + preparation us | Linear / cold prepared / warm prepared batch us | Prepared live-graph increment B |
| ---: | ---: | ---: | ---: | ---: |
| 2 | 0.004 | 0.034 | 0.029 / 0.063 / 0.054 | 152 |
| 30 | 0.021 | 1.626 | 1.853 / 2.580 / 0.981 | 1,944 |
| 300 | 0.248 | 26.947 | 146.446 / 48.777 / 21.683 | 19,224 |
| 3,000 | 5.146 | 505.542 | 14,639.500 / 767.812 / 266.730 | 192,024 |

The source-constructor cases start with already-created observed rows; neither
includes HTTP or JSON decode. Cold batch prepares an existing source view then
queries it, excluding that source's construction. Warm batch excludes its earlier
preparation and retained graph. At N=300, constructor+preparation allocates about
166.6 KB per operation; warm batch allocates about 4.9 KB versus linear 19.3 KB.
Actual reuse/refresh cadence and discarded-result cost have not been measured,
so these figures do not establish net runtime allocation savings.

Negative controls remain: the prepared batch is slower at N=2. At N=300 a
repeated first-name lookup is about 0.009 us linear, 27.397 us with preparation,
and 0.050 us when already prepared. At 3,000 entries both cold preparation and
the warm whole-roster batch exceed 100 us. These are component averages, not
the TUI's 100 us objective or a production latency verdict.

The separate live-memory process forces major collections before and after
preparing one value while the raw source remains reachable throughout. All five
N=300 samples report 2,403 additional live words (19,224 bytes on this 64-bit
runtime). This is one retained graph's increment, not RSS, heap capacity, peak
memory, multiple obsolete results, reclamation latency or actual refresh load.
CPU, allocation, every raw batch, live-word samples and source input hashes remain
under [keeper-roster-prepared-v1](keeper-roster-prepared-v1/).
That historical prototype also includes immutable physical-equality checks;
their success is compiler-specific and does not establish a language guarantee.

## Exact product-fragment checks

The two product-fragment bundles compile exact factory/getter/decision bodies
against reduced runtime record types and shared type aliases. V2 also checks
the adapted opaque interface. Each successful invocation records 1,262 reading
comparisons and 2,524 lifecycle-choice pairs. These are repeated checks over the
same parameter grid, not twice as many unique cases or complete-module tests.

V1 compared only a summary of source-view fields and made implementation-specific
immutable physical-equality assertions. Its `no native execution` wording refers
to the full product/TUI: an `ocamlopt` fragment executable did run. V2 compares
the complete, partial and invalid source-view constructors and reduced contents
structurally; its unobserved cases compare liveness only. It drops those
physical-equality assertions. The product duplicate test likewise checks
distinct runtime IDs and lifecycle choices rather than immutable pointer identity.
The original V1 result is preserved. Neither version executes the actual
workspace/HTTP admission path, full product module or TUI, or measures latency.

Independent adversarial and response source reviews inspected ownership,
consumers and the added lifecycle tests. Those reviews and excerpt executions
are separate from formal GitHub approval or completed product checks.

## Retention and reproduction

[provenance.json](provenance.json) pins 33 selected exact source/capture pairs
read after the invocations. Each execution receipt separately pins its listed
inputs/binary. Compiled component binaries/objects remain under ignored
`artifacts/`; retained source fragments and compile commands permit a new run.
Copy the relevant fixture/control and prototype sources into a fresh ignored
directory, compile in each receipt's order with OCaml 5.5.1 and its listed
packages/flags, then write a new output. Captured `.cmx` input hashes identify
the old object bytes; rebuilding elsewhere does not certify identical objects.

The product `prepare.py` files are extraction recipes for the recorded historical
base plus candidate working tree. They overwrite generated files beside
themselves, and must not run inside this retained bundle or a later committed
candidate checkout. For re-extraction use a separate checkout with the recorded
base/candidate and a copy of the helper in a new ignored output directory.
This bundle contains synthetic metadata and selected source/diagnostics; auth
configuration, full production/runtime data and native product binaries are
excluded.
