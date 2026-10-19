(** Exact read-only Task inspection. No list/current-Keeper fallback. *)
type detail =
  { task : Masc_domain.task
  ; canonical_goal_id : string option
  ; diagnostics : Masc_domain.task_decode_diagnostics }
val detail : task_id:string -> Yojson.Safe.t -> (detail, string) result
val history : task_id:string -> Yojson.Safe.t -> (Tui_decode.task_history_event list, string) result
(** History rows must name the captured Task through [task] or [task_id].
    Conflicting identities are rejected rather than shown under that Task. *)
type history = private
  { history_task_id : string
  ; history_events : Tui_decode.task_history_event list
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
    the observed stored prefix. Parsing/concatenation belongs on the CPU path. *)
