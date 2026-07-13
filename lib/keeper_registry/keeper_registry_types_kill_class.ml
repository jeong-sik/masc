(** Typed sub-classes for the keeper registry stale-watchdog kill
    + the [Ambiguous_partial_commit] failure-reason payload.

    [stale_kill_class] is the 4-variant typed kill-class introduced
    in Phase B PR-6 (2026-04-28) — it distinguishes idle-turn,
    in-turn-hung, mid-turn-no-progress, and noop-failure-loop kill
    paths, each carrying the timer/threshold fields the operator
    dashboard renders.

    [ambiguous_partial_commit] tags a partial-commit failure with
    the kind (post-commit timeout vs post-commit failure) + the
    operator-facing detail string.

    Pure variants + records + total [to_string] helpers. Verbatim
    extract from the head of [Keeper_registry_types]; the parent
    retains transparent aliases (type + record + variant) so the
    .mli concrete declarations and the [failure_reason] variants
    that reference these types continue to type-check unchanged. *)

type ambiguous_partial_commit_kind =
  | Post_commit_timeout
  | Post_commit_failure

type ambiguous_partial_commit =
  { kind : ambiguous_partial_commit_kind
  ; detail : string
  }

(** Phase B PR-6 (2026-04-28): typed sub-class of stale-watchdog kills.
    See keeper_registry.mli for rationale.

    task-2285 (2026-07-13): added [Alive_idle] variant to distinguish
    a keeper that is alive (heartbeats arriving) but not producing turns
    from a truly frozen keeper that has stopped heartbeating entirely. *)
type stale_kill_class =
  | Alive_idle of
      { stall_seconds : float
      ; since_heartbeat_seconds : float
      }
  | Idle_turn of { stall_seconds : float }
  | Mid_turn_no_progress of
      { active_seconds : float
      ; since_progress_seconds : float
      ; progress_timeout_threshold : float
      ; last_progress_kind : string option
      }
  | Noop_failure_loop of { noop_count : int }

let progress_kind_label = function
  | Some kind -> kind
  | None -> "-"
;;

let stale_kill_class_to_string = function
  | Alive_idle { stall_seconds; since_heartbeat_seconds } ->
    Printf.sprintf "alive_idle(stall=%.0fs hb=%.0fs)" stall_seconds since_heartbeat_seconds
  | Idle_turn { stall_seconds } -> Printf.sprintf "idle_turn(%.0fs)" stall_seconds
  | Mid_turn_no_progress
      { active_seconds
      ; since_progress_seconds
      ; progress_timeout_threshold
      ; last_progress_kind
      } ->
    Printf.sprintf
      "mid_turn_no_progress(active=%.0fs since_progress=%.0fs threshold=%.0fs last=%s)"
      active_seconds
      since_progress_seconds
      progress_timeout_threshold
      (progress_kind_label last_progress_kind)
  | Noop_failure_loop { noop_count } ->
    Printf.sprintf "noop_failure_loop(noop=%d)" noop_count
;;

let ambiguous_partial_commit_kind_to_string = function
  | Post_commit_timeout -> "post_commit_timeout"
  | Post_commit_failure -> "post_commit_failure"
;;
