module B = Keeper_turn_boundaries
module P = Keeper_librarian_progress
module O = Keeper_librarian_official_progress
module Checkpoint = Keeper_checkpoint_store.Read_observation

type boundary =
  | Refused_line
  | Incomplete_line
  | Restarted of string
  | Ended of string * B.history_at_start * B.position

type key =
  { keeper_dir : string
  ; session_dir : string
  ; keeper_id : Keeper_identity.Keeper_id.t
  ; keeper_uid : Keeper_id.Uid.t option
  ; created_at : string
  ; trace_id : string
  ; boundaries : (int * boundary) list
  ; progress : P.t option
  ; official_cursor : O.t option
  }

type t =
  { key : key
  ; atoms : int
  ; witness : Checkpoint.t
  }

let boundary = function
  | Error (B.Not_json _ | B.Malformed _) -> Refused_line
  | Error B.Incomplete_line -> Incomplete_line
  | Ok { B.recorded_at = _; event = B.History_restarted { trace_id } } ->
    Restarted trace_id
  | Ok { B.recorded_at = _; event = B.Turn_ended
      { turn_ref; task_context = _; history_at_start; position } } ->
    Ended (Ids.Turn_ref.trace_id turn_ref, history_at_start, position)

let key ~keeper_dir ~session_dir ~keeper_id ~keeper_uid ~created_at ~trace_id
    ~lines ~progress ~official_cursor =
  { keeper_dir; session_dir; keeper_id; keeper_uid; created_at; trace_id
  ; boundaries = List.map (fun (line, read) -> line, boundary read) lines
  ; progress; official_cursor
  }

let equal_progress (left : P.t) (right : P.t) =
  left.boundary_lines_seen = right.boundary_lines_seen
  && String.equal left.position.trace_id right.position.trace_id
  && left.position.end_atom = right.position.end_atom
  && String.equal left.position.last_atom_digest right.position.last_atom_digest

let equal_key left right =
  String.equal left.keeper_dir right.keeper_dir
  && String.equal left.session_dir right.session_dir
  && Keeper_identity.Keeper_id.equal left.keeper_id right.keeper_id
  && Option.equal Keeper_id.Uid.equal left.keeper_uid right.keeper_uid
  && String.equal left.created_at right.created_at
  && String.equal left.trace_id right.trace_id
  && Option.equal equal_progress left.progress right.progress
  && Option.equal (fun (left : O.t) (right : O.t) ->
       left.boundary_line = right.boundary_line) left.official_cursor right.official_cursor
  (* These are closed count-input variants, containing only strings and
     integers. Exact structural equality neither hashes nor serializes rows;
     task contexts and error bodies never enter the projected value. *)
  && left.boundaries = right.boundaries

let remember key ~atoms ~witness = { key; atoms; witness }

let reuse key observation =
  if not (equal_key key observation.key) then None
  else match Checkpoint.revalidate observation.witness with
    | Checkpoint.Unchanged -> Some observation.atoms
    | Checkpoint.Changed | Checkpoint.Unavailable _ -> None
