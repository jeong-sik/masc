(** Exact read-only Task inspection. No list/current-Keeper fallback. *)
type detail =
  { task : Masc_domain.task
  ; canonical_goal_id : string option
  ; diagnostics : Masc_domain.task_decode_diagnostics }
val detail : ?previous:detail -> task_id:string -> Yojson.Safe.t -> (detail, string) result
(** Always validate and decode the new response. After exact typed Task equality,
    reuse only the previous immutable Task object. Canonical Goal and diagnostics
    come from the new response. The caller may supply a previous reading only
    for the same captured original source and workspace; this is no
    admission, freshness or authority cache. Run decoding/equality on the CPU path. *)
val history : task_id:string -> Yojson.Safe.t -> (Tui_decode.task_history_event list, string) result
(** History rows must name the captured Task through [task] or [task_id].
    Conflicting identities are rejected rather than shown under that Task. *)
type history = private
  { history_task_id : string
  ; history_events : Tui_decode.task_history_event list
  ; history_records : Yojson.Safe.t list
  ; history_verifications : string list
  ; history_next_cursor : string option
  ; history_cursors : string list }
type history_request = private
  { hr_task_id : string; hr_limit : int; hr_cursor : string option
  ; hr_prefix : history option }
val history_first : task_id:string -> limit:int -> history_request
(** A fresh observed prefix. The per-response demand has the protocol minimum
    of one; it is not a total history cap. *)
val history_earlier : task_id:string -> limit:int -> history -> history_request option
(** Only the same original Task's known older cursor can extend that prefix.
    [None] means no older boundary is known; it is not a fresh-read fallback. *)
val history_page : request:history_request -> Yojson.Safe.t -> (history, string) result
(** Validate exact Task, request-cursor echo, schema and page demand before
    appending to the captured immutable prefix. A missing next cursor ends only
    the observed stored prefix. Exact verification ids retain first-observed
    order across the prefix; malformed ids fail rather than disappear.
    Original records remain available for explicit full evidence reading;
    display summaries do not erase verdict reasons or authority metadata.
    Parsing/concatenation belongs on the CPU path. *)

type deletion_cleanup = Cleanup_required | Cleanup_verified
type deletion_observation = {
  deletion_id : string; requested_at : string; cleanup : deletion_cleanup;
}
type observation =
  | In_backlog of detail
  | In_archive of detail
  | Not_observed
  | Deletion_recorded of deletion_observation
val observation : task_id:string -> Yojson.Safe.t -> (observation, string) result
(** Exact versioned original Task observation; no global-list/current-Keeper
    fallback. A deletion record is historical evidence, not physical cleanup
    or future absence proof. Not_observed is inconclusive. *)
