---
rfc: "0062"
title: "Typed tool-result failure classification"
status: Implemented
---

# RFC-0062 — Typed tool-result failure classification

**Status**: Implemented
**Owner**: `Tool_result`

## Contract

Every tool invocation returns `Tool_result.result`, whose disposition is one of:

- `Completed output`
- `Deferred output`
- `Failed failure`

`Failed` always carries a required `tool_failure_class`:

- `Transient_error`: a retry may succeed without changing the request.
- `Policy_rejection`: the request violates authentication, authorization, validation, or a safety boundary.
- `Runtime_failure`: the implementation or runtime failed unexpectedly.
- `Workflow_rejection`: the request conflicts with the current business or task state.

The producing boundary owns this classification. Message contents never determine
the class, and exception constructors do not supply a default class. A catch site
must pass `~class_` explicitly to `Tool_result.make_err_of_exn`.

## Typed argument errors

`Tool_args.error_code` is the closed input-error vocabulary. Its exhaustive
projection into `tool_failure_class` is:

| Error code | Failure class |
|---|---|
| `Validation_error`, `Not_found`, `Auth_required`, `Permission_denied` | `Policy_rejection` |
| `Conflict`, `Precondition_failed` | `Workflow_rejection` |
| `Rate_limited`, `Timeout` | `Transient_error` |
| `Not_implemented`, `Internal_error` | `Runtime_failure` |

Handlers project `Tool_args.error_code` through
`Tool_args.failure_class_of_error_code` and construct `Tool_result.Failed` at
the handler boundary.
Low-level JSON boundaries use the canonical `Tool_args.error_response`,
`error_response_with`, or `error_assoc` constructors.

## Boundary rules

1. Internal consumers branch on the `Tool_result.disposition` constructor.
2. Failure routing, retry, metrics, and logging consume `tool_failure_class`.
3. External protocols may project the typed result into their wire envelope, but
   that projection must not become a second outcome authority.
4. `Deferred` remains distinct from `Completed`; boolean success projections are
   boundary-only views.

## Verification

- `test/test_tool_result.ml` pins constructors, accessors, and retry policy.
- `test/test_tool_args_envelope.ml` pins every `error_code` projection.
- `test/test_tool_dispatch.ml` pins explicit runtime and timeout classes at the
  dispatch exception boundary.
- `test/test_dispatch_observer_validation_failure.ml` pins the observer projection.
- Required CI executes these suites through the tool-input constraint target.
