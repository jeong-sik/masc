# Schedule compact JSON: one UTF-8 repair pass

The Schedule writer repaired the JSON value for its written-state cache, then
passed it to a compact encoder that repaired it again. The change returns the
compact bytes and their repaired writer input together. Schedule still decodes
that repaired value inside the same CPU job before the existing primary,
mirror and cache publication decisions.

The returned value is the writer input. It is not a general replacement for
parsing the wire bytes: numeric literals can normalize differently on readback.
Schedule already decoded the first repaired input before this change.

## Owned pure-pipeline measurement

`observed.json` is the unchanged native output. `owned_probe.ml` is the exact
synthetic probe, using the complete actual Safe_ops implementation and interface
at source head `9eefdd3136331b5cf36bdb4db2708fd6ffc65cf4`. The source file hashes
are in `provenance.json`; this is not a claim that the whole product was built.
The probe compares repair twice plus the compact writer with repair once plus
the same writer, returning the first repaired value in both cases.

The run passed 825 semantic assertions, including all 256 byte values, malformed
UTF-8, duplicate object keys, controls, Unicode, signed zero and matching writer
errors for non-finite floats. Raw `Intlit "0007"` preserves existing writer
behavior; this does not establish strict JSON parseability for every input.

There were three fixtures, four alternating AB/BA paired rounds per fixture and
16 calls per side per round: 384 measured calls, 64 per side per fixture.

| Raw fixture label | Encoded bytes | Median process CPU ratio, once/twice | Median allocation-counter ratio |
| --- | ---: | ---: | ---: |
| ascii-256KiB | 264530 | 0.7661 | 0.9814 |
| unicode-256KiB | 231762 | 0.7193 | 0.9687 |
| ascii-4MiB | 4194914 | 0.7704 | 0.9997 |

The Unicode fixture's raw label overstates its text payload: it contains
224 KiB, not 256 KiB. All twelve CPU pairs favored one pass. Eleven wall-time
pairs did; the remaining ASCII 256 KiB pair was slower. Host scheduling was
uncontrolled. Allocation counters include measurement overhead and are not
retained memory, peak memory or RSS. The probe calls full-major GC only in its
own process before each measurement. It makes no runtime request or GC call.

These ratios apply to the synthetic encoding pipeline, not complete Schedule
mutations, HTTP latency, the installed server or the whole host.

## Actual consumer validation

The retained native records use complete actual modules and compatible existing
prebuilt dependencies, with fatal warnings 4, 8, 32 and 69. They use isolated
compilation-unit names; no fake interface or warning suppression was introduced.

- The complete encoder implementation/interface, complete Workspace facade and
  complete maintained Workspace coverage suite compiled. All 60 cases passed.
  The first executable name lacked the required `test_` prefix and selected
  production base-path policy; the same binary bytes with the actual test name
  passed under an owned temporary base path. No product bypass was added.
- The complete Schedule implementation/interface and complete actual TestDeps
  implementation compiled. The full Schedule test implementation failed on
  existing fragile matches under fatal warning 4. It did not link or run.
- Ten unchanged maintained Schedule cases, four unchanged helpers and their
  unchanged common prelude compiled and passed. They cover primary/mirror
  authority and failure, observer unlock behavior, last-good bytes, worker
  execution, unchanged-file cache, written-state cache and repaired-state parity.
  The first selected link lacked `masc_test_unsetenv`; the successful run compiled
  and linked the complete unchanged actual C stub, rather than a dummy symbol.

`validation.json` is a curated derivative of the local command records: it keeps
labels, exit statuses and elapsed times, and hashes the original command files.
It omits their host-specific compiler argument lists. The unchanged retained
logs and review records have separate hashes. The compile dependencies were not
attested as a complete build of the product source head. No local Dune build,
CI, installation or full Schedule regression was performed for this change.

The independent lower and upper source reviews name their exact pre-publication
heads and checked source hashes. They found no P0/P1/P2 in their stated units;
they are source-review records, not GitHub account approvals or runtime recovery.
`review-scope-addendum.json` preserves the measurement qualifications alongside
the original records. No server CPU/RSS recovery is established here.
