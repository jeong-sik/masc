(** Reference-aware retention for per-turn Keeper raw traces.

    The current TurnRecord window is the reachability root. A trace named by
    one of those records is never a deletion candidate. Cleanup runs only
    after the current TurnRecord commit attempt, so an unreferenced file is
    diagnostic garbage, not an in-flight write. *)

val history_limit : int
(** Number of newest physical TurnRecord rows inspected by both the dashboard
    reader and retention. This is the single source of truth for RFC-0358. *)

type deletion_failure =
  { path : string
  ; detail : string
  }

type summary =
  { removed : int
  ; retained_references : int
  ; candidate_files : int
  ; deletion_failures : deletion_failure list
  }

type error =
  | Turn_record_store_unreadable of string
  | Malformed_turn_record of
      { path : string
      ; line_number : int option
      ; detail : string
      }
  | Incompatible_turn_record of string
  | Wrong_keeper_turn_record of
      { expected : string
      ; actual : string
      }
  | Invalid_raw_trace_reference of string
  | Raw_trace_directory_unreadable of string

val error_to_string : error -> string

val prune :
  config:Workspace.config ->
  keeper_name:string ->
  unit ->
  (summary, error) result
(** Delete regular [.jsonl] files that are unreachable from the newest
    {!history_limit} TurnRecords. Callers invoke this only after the current
    TurnRecord commit attempt, never while its raw trace is still being
    written.

    Any uncertainty while reading or decoding the reachability root returns
    [Error] before deletion (fail-open). Individual unlink failures are
    collected in [summary] and never fail the Keeper turn. *)
