(** RFC-0070 Phase 3c.1 — Typed backoff policy for sandbox retry.

    Replaces RFC §3.4's magic "3 retries" prose with a typed value
    that the caller resolves once (typically from configuration) and
    threads through the retry-aware executor calls.

    Reference: docs/rfc/RFC-0070-keeper-sandbox-pure-edge-separation.md §3.4

    Determinism contract: a policy value is *pure data*. No clock, no
    Random. The same [(policy, error-sequence)] sequence ⇒ identical
    retry decisions. *)

(** Abstract policy value. Use {!make} or {!default_for_sandbox}. *)
type t

(** [make ~max_attempts ~retryable_errors] constructs a policy.
    [max_attempts] is the *total* number of calls including the first
    (so [max_attempts = 1] disables retry).
    [retryable_errors] enumerates exactly the {!Docker_client.sandbox_error}
    arms that warrant a retry — *no catch-all*, the caller must
    enumerate every retryable variant. *)
val make
  :  max_attempts:int
  -> retryable_errors:Docker_client.sandbox_error list
  -> t

(** [default_for_sandbox] is the canonical policy for Sandbox_executor:
    - [max_attempts = 3]
    - [retryable_errors = \[ Daemon_unreachable; Image_pull_failed \]]

    Daemon_unreachable + Image_pull_failed are *transient* network
    failures worth retrying. Other [sandbox_error] arms (Container_oom,
    Exec_timeout, Probe_format_drift, Cleanup_failed) are *non-
    transient* and surface immediately to the caller. *)
val default_for_sandbox : t

(** [max_attempts t] returns the total-call budget. *)
val max_attempts : t -> int

(** [should_retry t err] returns [true] iff [err] is one of [t]'s
    declared retryable variants. Strict — variants not in the list
    return [false]. *)
val should_retry : t -> Docker_client.sandbox_error -> bool
