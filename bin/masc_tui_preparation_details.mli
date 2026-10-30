(** Selected, durable preparation evidence. No execution/resume authority. *)
type target
val target :
  journal:Masc_tui_keeper_chat_log.t -> execution_id:string -> reply_turn_ref:string option ->
  (target, string) result
(** Autonomous journals supply their exact Turn_ref. Direct journals require a
    reply or exact terminal operation outcome reference and the actual execution
    ID, including batch binding. Two recorded references must agree.
    The journal object and its revision identify the local observation generation;
    neither a Keeper name nor a timestamp supplies a missing execution link. *)
val path : target -> string

type issue =
  | Partial_scan | Partial_return | Missing_manifest
  | Scan_unsupported_events of int
  | Scan_invalid_manifest_rows of int | Scan_invalid_json_rows of int
  | Unsupported_rows of int | Invalid_rows of int
  | Invalid_report of string | Duplicate_report of string | Unlinked_report
(** [Scan_*] counts describe the server's scanned window, not the returned
    page. Unsupported events have a matching turn identity; malformed JSON
    and manifest rows cannot be attributed to the selected turn.
    [Unsupported_rows] and [Invalid_rows] describe returned rows. Keep the
    scopes separate; none of these counts is a failed-work count. *)
type snapshot = private
  { observed_target : target
  ; reports : Masc.Keeper_preparation_runtime_observation.report list
  ; issues : issue list
  }
val decode : target:target -> Yojson.Safe.t -> (snapshot, string) result
(** Read the existing runtime-trace response, validate envelope/turn/report
    ownership and retain partial/unsupported/invalid evidence explicitly.
    Duplicate report IDs are excluded, never chosen by time or list position.
    An empty result does not prove no preparation occurred. *)

type t
type request
type recheck = Recheck_pending | Recheck_loading | Recheck_failed of string
type view =
  | Not_loaded | Loading | Failed of string | Loaded of snapshot
  | Retained of { snapshot : snapshot; recheck : recheck }
val empty : t
val refresh : keeper_name:string -> t -> t
(** Retire this Keeper's pending read and completed read freshness, retaining
    its last successful snapshot for the same exact original target only.
    The next visible selection starts a fresh request capability. Refreshing
    another Keeper does not retire this selection's read. *)
val select : target option -> t -> t * request option
(** One current read for the selected journal revision. Hiding details keeps
    that owned read and can cache its result without displaying it. Selecting
    another execution retires the previous request. A completed result is reused for that exact
    journal/revision; no all-Keeper cache or history scan is introduced. *)
val requested_target : request -> target
val receive : request -> (snapshot, string) result -> t -> t
(** Only the still-current request capability may settle this selection. *)
val view : target -> t -> view
(** Retained observations are never confirmed by a pending/failed recheck.
    A changed journal/revision or original execution cannot display them.
    Workspace retirement discards [t] with [empty]. *)
