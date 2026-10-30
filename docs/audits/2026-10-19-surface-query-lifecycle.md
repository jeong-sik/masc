# Surface query lifecycle through cold identity rebinding

Source comparison base: `42e4410e3e46a5fa6e5e8a96cca51ee6bc68bb89` (#43759).
This is a source-derived Before/After, not an observed runtime or timing result.

## Finding and resulting behavior

Full dispatch captured the Board query but emitted no surface dispatch log.
Navigation emitted its request without that input. A cold matching identity
retires old data owners and dispatches a new Full surface request before collection;
the acknowledgement carried that new request without an original-query link.
Cleanup carried only the latest request, so an unfinished or rebound read could
not be attributed through the same captured context. Synchronous normal-return
fallback had no equivalent finished event.

| Boundary | Before | After |
| --- | --- | --- |
| Full logical dispatch | No surface-start line | One intent/context start line |
| Navigation logical dispatch | Start line without input context | Same fields plus context |
| Cold admitted owner replacement | Fresh request without original-query link | Previous owner linked to immutable origin/current context |
| Acknowledgement and completion | Current bare request | Same current opaque request inside context |
| Early/terminal data admission | Current request checks | Extract exactly that current request; metadata grants no authority |
| Synchronous normal-return cleanup | No finished event | Shared cleanup context/event |
| Start without observed cleanup | Incomplete attribution | Retained unfinished context; no invented end |
| Board not originally requested | No captured intent fact | Null planned query, independent of later controls |

`Surface_read_context` contains two existing opaque requests (origin/current) and
optional planned Board query; no mutable history, new id, clock owner or request
counter. Capture uses the same needs/query snapshot as the producer. Rebind changes
only current request. Private `.mli`/`.ml` acknowledgement and completion payloads
carry this value; existing dataset messages and terminal records still carry their
original current request, and existing workspace/ticket/dataset checks remain.

Schema-1 context JSON projects each request's session-local id, kind and monotonic
dispatch clock. Planned query is intent, not delivery or current controls. A full
pass may perform only the existing identity probe while booting; logical dispatch
is not a Board HTTP-start claim. Rebound means UI owner creation/acknowledgement
offer, not worker consumption or network entry. Finished means observed UI cleanup,
not received data, real worker exit, paint or Task progress. Duplicate/retired
navigation completion keeps its existing suppression policy.

Logs stay outside finalizers, with existing cancellation/exception propagation.
An exception or cancellation can leave only start/rebind; retain those records as
unfinished, without assigning a completion time or adding a timeout. Query metadata
is never read as an authorization or scheduling gate. No response, draft, body,
error text, credential or workspace path is added to these context objects.

## Authored scenarios and evidence limits

Two new compound state/ownership scenarios exercise original query and immutable
origin across admitted-owner replacement, old cleanup rejection, actual successor
receipt application with later controls and retained draft, terminal non-replay,
non-Board intent alongside a new Board navigation, withdrawal and late cleanup.
The Board suite grows from six to eight cases. One existing cold identity guard
scenario also captures intent before controls change and verifies that foreign,
incomplete, booting, warm and retired authority decisions are not granted by it.
Assertions inspect typed intent/state/ownership/decisions, without wording,
layout/screen-order, snapshot-output, serialization-string or PTY expectations.
The private acknowledgement/worker/loop paths are source-inspected, not executed
by these scenarios; no test-only facade/library extraction is introduced.

No local Dune/typecheck/tests, CI dispatch/watch, native/model run, install/restart,
live prompt/config write, independent approval, own merge or actual log/paint
verification. Parsing and diff/changelog metadata checks are the only executed
checks. Extra HTTP/health reads, independent ids/generations, retries, deadlines
and UI rows are zero. The two Board GET readers remain two. The existing monotonic
clock source is reused; synchronous normal-return cleanup adds an observation read.
Context formatting and additional full-start/rebind/fallback log writes add
unmeasured overhead. No loading, first-input, preparation, model or useful-work
speedup is claimed.

The entire preparation/discovery reuse, cold-start input/readability/observability,
Ask-to-original-Task/useful-work, resource-owned Composition, held-job/shared-backend
and matched Before/After goal remains active. Failed/cancelled/interrupted/unfinished
samples remain part of its evidence requirements.
