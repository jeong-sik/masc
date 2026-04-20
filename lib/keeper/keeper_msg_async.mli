(** Keeper_msg_async — Fire-and-forget keeper message execution.

    Background fibers run [keeper_msg] turns. MCP tool returns
    immediately with a [request_id]; clients poll via
    [masc_keeper_msg_result] for completion. Entries auto-expire
    after [max_age_sec] (1h) to prevent memory leaks. *)

(** {1 Types} *)

type request_status =
  | Queued
  | Running
  | Done of { ok : bool; body : string }

type entry = {
  request_id : string;
  keeper_name : string;
  status : request_status;
  submitted_at : float;
  completed_at : float option;
}

(** {1 Submit and poll} *)

(** [submit ~sw ~f ~keeper_name] forks a background daemon fiber on
    [sw] that runs [f] and stores the result. Returns the fresh
    [request_id] synchronously. Cancellation of [sw] cancels the
    fiber. *)
val submit :
  sw:Eio.Switch.t ->
  f:(unit -> Keeper_types.tool_result) ->
  keeper_name:string ->
  string

(** [poll request_id] returns the current entry, or [None] when the
    id is unknown or has expired. *)
val poll : string -> entry option

(** [list_for_keeper ~keeper_name] returns all entries for a keeper
    sorted most-recent-first. *)
val list_for_keeper : keeper_name:string -> entry list

(** {1 JSON output} *)

val status_to_string : request_status -> string

(** JSON encoding with [request_id], [keeper_name], [status],
    [submitted_at], and — depending on state — [completed_at] /
    [elapsed_sec] / [ok] + [result]. *)
val entry_to_json : entry -> Yojson.Safe.t
