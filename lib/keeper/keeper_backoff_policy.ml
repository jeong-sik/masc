(* RFC-0070 Phase 3c.1 — Backoff policy typed value. See .mli. *)

type t =
  { max_attempts : int
  ; retryable_errors : Docker_client.sandbox_error list
  }

let make ~max_attempts ~retryable_errors =
  if max_attempts < 1 then
    invalid_arg
      (Printf.sprintf
         "Keeper_backoff_policy.make: max_attempts must be >= 1 (got %d)"
         max_attempts);
  { max_attempts; retryable_errors }

let default_for_sandbox =
  { max_attempts = 3
  ; retryable_errors =
      [ Docker_client.Daemon_unreachable
      ; Docker_client.Image_pull_failed
      ]
  }

let max_attempts t = t.max_attempts

(* Exhaustive match against the closed sum — every variant explicitly
   classified. Adding a new variant to [Docker_client.sandbox_error]
   forces this match to compile-error until the new arm is classified
   as retryable or not. *)
let sandbox_error_equal (a : Docker_client.sandbox_error) (b : Docker_client.sandbox_error) =
  match a, b with
  | Daemon_unreachable, Daemon_unreachable -> true
  | Image_pull_failed, Image_pull_failed -> true
  | Container_oom, Container_oom -> true
  | Exec_timeout, Exec_timeout -> true
  | Probe_format_drift, Probe_format_drift -> true
  | Cleanup_failed, Cleanup_failed -> true
  | Daemon_unreachable, _
  | Image_pull_failed, _
  | Container_oom, _
  | Exec_timeout, _
  | Probe_format_drift, _
  | Cleanup_failed, _ -> false

let should_retry t err = List.exists (sandbox_error_equal err) t.retryable_errors
