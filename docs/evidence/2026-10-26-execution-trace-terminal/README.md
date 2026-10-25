# Execution result versus terminal trace failure — #27890

## Concrete authority defect

Agent.run's Raw_trace wrapper encloses its durable execution scope. The inner scope can commit its terminal result and close its writer before Raw_trace.finish_run appends its final observation. The old finalization Error branch replaced the returned execution result, completion callback outcome and lifecycle with the trace error. A caller could therefore see failure after an external tool effect and canonical success had already committed.

Finalization now reports a trace append failure separately and returns the original execution result. Completion callbacks and lifecycle use that original result. A local best-effort reporter isolates ordinary diagnostic sink exceptions, including the warning that follows an ordinary completion callback exception. Reserved exceptions still propagate, and Fun.protect finalizes lifecycle even when reporting or a callback is preempted. An original raised run exception and its raw backtrace remain primary unless a reserved reporting exception preempts them.

This is the terminal outcome-isolation condition of #27890. It does not make Raw_trace or Event_bus read-only canonical projections, add journal checkpoint facts, remove transient execution, or define retention. Those original hard-cut requirements remain open. No dual writer/compatibility adapter is introduced.

## Public producer-to-consumer proof

Changed agent_trace finalization interface → Agent.run and Advanced paths → public Pipeline fixture, existing periodic cleanup and Advanced Agent suites. The new fixture runs an actual local custom provider transport and Tool handler with an execution store. The terminal callback first opens the canonical read-only projection and observes success, then replaces the trace path with a directory to force a real append error. No provider HTTP is sent.

Four controls cover ordinary trace error, ordinary throwing diagnostic sink, reserved Sys.Break diagnostic and a completion callback that raises followed by a throwing warning sink. They assert one external effect, original API answer or reserved propagation as appropriate, callback outcome, lifecycle, a fresh projection's identical committed events/terminal/cursor and no compensating journal failure after the same cursor. A fresh same-process reader is not an OS restart. Directory replacement targets only a temporary fixture path and is cleaned up.

## Execution history

- Baseline86d40fd702462bcff0711fb050b70224bd23d315 /40207942132: actual69,68PASS/1FAIL. Canonical success and one effect were observed, then API returned trace append error. Later callback/lifecycle/fresh-projection assertions in that failed case were unreached.
- Intermediateb52b5c908b8bb34c283f7ff060222a2beb001065 /40208003373: SUCCESS99=Pipeline69+periodic9+Advanced21. This lacked the later diagnostic and callback fault controls, so it does not prove final isolation.
- Diagnostic baseline33c7d2b0a8d777cb3bb86bd8c9aff8eb0dde866c /40208272091: actual71,69PASS/2FAIL. Throwing ordinary diagnostic escaped; reserved diagnostic left lifecycle inconsistent. Later assertions in each failed case were unreached.
- Diagnostic fix75e136cb7268871beba18a9a78c7ef9d1c7d5425 /40208310420: SUCCESS101=Pipeline71+periodic9+Advanced21. Review then found the completion callback warning's separate throwing-sink path; that fourth control is absent here.
- Final source8f6e942ec4abb8baf7e543780398f159d8199a30 /40208521594: same three suites dispatched with the fourth combined control; outcome unobserved at this evidence boundary.

Three source/fixture hashes and four complete raw-log SHA/byte counts with selected checkout/assertion/summary lines are retained. Local OCaml syntax parsing, fragment and full whitespace checks pass; they are not execution evidence. No local Dune build, full regression, vendor HTTP, installed runtime, visible UI, deployment, merge or whole-issue completion claim.

Two independent source reviewers refreshed SOURCE PASS at8f6e942ec4abb8baf7e543780398f159d8199a30/base25ba22387ffe0d71be8e0f8e58cb66b4bfa5237a/diffa87f75626e89e71a37afcfd8d6d1c600dd6e18e94fa7e30ef454aa2d212c7089 after both P2 diagnostic findings. These are source assessments, not formal GitHub approvals. gh stack adopted the single main-based branch; submission reports repository disabled, REST stack:null. Original #27890 remains OPEN.

## Actual final result

[Final40208521594](https://github.com/jeong-sik/masc/actions/runs/40208521594) completed SUCCESS at exact8f6e942ec4abb8baf7e543780398f159d8199a30: **102 actual cases PASS** (Pipeline72+periodic cleanup9+Advanced21). All four new post-commit fault controls reached the result/reserved-propagation, callback, lifecycle, fresh projection, identical event/cursor and zero compensating-event assertions. Existing raised exception/backtrace and cooperative yield behavior remain exercised by the selected suites. This supersedes the pending observation above. Earlier99/101 successes are not added to102 or counted as proof of the later controls. Evidence-only follow-up preserves allthree source/fixture hashes and retains five raw-log digests.
