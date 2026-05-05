(** Pin the per-variant retryable classification of [masc_error].

    Audit-driven addition (2026-04-29 Implementation Quality
    Audit §"Re-tryability"): MASC was missing an
    [is_retryable] predicate on its [masc_error] sum, so callers
    fell back on an OAS-only helper.  This suite locks the
    classification so future variant additions force a deliberate
    "retryable or not" decision.

    Properties pinned:
    1. {b Domain-state errors are non-retryable} — Task / Agent /
       Portal variants.
    2. {b Auth — only TokenExpired retryable} — refresh-then-retry
       semantics; Unauthorized / Forbidden / InvalidToken are not.
    3. {b System — only transient I/O retryable} — IoError /
       StorageError; remaining caller-invariant violations
       (NotInitialized, InvalidJson, ValidationError, …) are not.
    4. {b Rate limit retryable} — replay after wait_seconds.
    5. {b Cache — corruption non-retryable, others retryable} —
       Read/Write/Expired retry; Corrupted is data-invariant. *)

module E = Masc_error

(* ── (1) Domain-state errors: never retryable ──────────── *)

let test_task_errors_non_retryable () =
  assert (not (E.is_retryable (E.Task (E.Task_error.NotFound "id"))));
  assert (
    not
      (E.is_retryable
         (E.Task
            (E.Task_error.AlreadyClaimed
               { task_id = "id"; by = "alice" }))));
  assert (not (E.is_retryable (E.Task (E.Task_error.NotClaimed "id"))));
  assert (
    not (E.is_retryable (E.Task (E.Task_error.InvalidState "x"))));
  assert (not (E.is_retryable (E.Task (E.Task_error.InvalidId "y"))))

let test_agent_errors_non_retryable () =
  assert (
    not (E.is_retryable (E.Agent (E.Agent_error.NotFound "n"))));
  assert (
    not (E.is_retryable (E.Agent (E.Agent_error.NotJoined "n"))));
  assert (
    not (E.is_retryable (E.Agent (E.Agent_error.AlreadyJoined "n"))));
  assert (
    not (E.is_retryable (E.Agent (E.Agent_error.InvalidName "x"))))

let test_portal_errors_non_retryable () =
  assert (
    not (E.is_retryable (E.Portal (E.Portal_error.NotOpen "a"))));
  assert (
    not
      (E.is_retryable
         (E.Portal
            (E.Portal_error.AlreadyOpen
               { agent = "a"; target = "b" }))));
  assert (
    not (E.is_retryable (E.Portal (E.Portal_error.Closed "a"))))

(* ── (2) Auth: only TokenExpired retryable ─────────────── *)

let test_auth_token_expired_retryable () =
  assert (
    E.is_retryable (E.Auth (E.Auth_error.TokenExpired "agent")))

let test_auth_other_non_retryable () =
  assert (
    not
      (E.is_retryable (E.Auth (E.Auth_error.Unauthorized "x"))));
  assert (
    not
      (E.is_retryable
         (E.Auth
            (E.Auth_error.Forbidden { agent = "a"; action = "x" }))));
  assert (
    not
      (E.is_retryable (E.Auth (E.Auth_error.InvalidToken "x"))))

(* ── (3) System: transient I/O retryable, others not ──── *)

let test_system_io_retryable () =
  assert (E.is_retryable (E.System (E.System_error.IoError "x")));
  assert (
    E.is_retryable (E.System (E.System_error.StorageError "x")))

let test_system_caller_invariants_non_retryable () =
  assert (
    not (E.is_retryable (E.System E.System_error.NotInitialized)));
  assert (
    not
      (E.is_retryable
         (E.System E.System_error.AlreadyInitialized)));
  assert (
    not
      (E.is_retryable (E.System (E.System_error.InvalidJson "x"))));
  assert (
    not
      (E.is_retryable
         (E.System (E.System_error.InvalidFilePath "x"))));
  assert (
    not
      (E.is_retryable
         (E.System (E.System_error.ValidationError "x"))))

(* ── (4) Rate limit retryable ──────────────────────────── *)

let test_rate_limit_retryable () =
  let err =
    {
      E.category = E.GeneralLimit;
      current = 11;
      limit = 10;
      wait_seconds = 30;
    }
  in
  assert (E.is_retryable (E.RateLimitExceeded err))

(* ── (5) Cache: corruption non-retryable, rest retryable  *)

let test_cache_transient_retryable () =
  assert (
    E.is_retryable (E.CacheError (E.CacheReadFailed "/p")));
  assert (
    E.is_retryable (E.CacheError (E.CacheWriteFailed "/p")));
  assert (
    E.is_retryable
      (E.CacheError
         (E.CacheExpired { key = "k"; age_hours = 1.0 })))

let test_cache_corrupted_non_retryable () =
  assert (
    not
      (E.is_retryable
         (E.CacheError (E.CacheCorrupted "/p"))))

(* ── runner ───────────────────────────────────────────── *)

let () =
  test_task_errors_non_retryable ();
  test_agent_errors_non_retryable ();
  test_portal_errors_non_retryable ();
  test_auth_token_expired_retryable ();
  test_auth_other_non_retryable ();
  test_system_io_retryable ();
  test_system_caller_invariants_non_retryable ();
  test_rate_limit_retryable ();
  test_cache_transient_retryable ();
  test_cache_corrupted_non_retryable ();
  print_endline "test_masc_error_is_retryable: all assertions passed"
