(** Historical admission evidence attached to selected sources, never current
    Task/Goal authority. Message offsets refer to the existing [turn=N] prompt
    labels (zero based, exclusive upper bound), not absolute Keeper turns. *)
type source =
  | Atom_span of { trace_id : string; start_atom : int; end_atom : int }
  | Official_turn
  | Boundary_only

type attribution =
  | Observed of { turn_ref : Ids.Turn_ref.t;
      task_context : Keeper_turn_task_context.t }
  | Unattributed

type scope = { source : source; attribution : attribution }
type t = { scope : scope; first_message : int; after_message : int;
  first_tool_observation : int; after_tool_observation : int }

val atom_spans : trace_id:string -> messages:Agent_core.Types.message list ->
  start_atom:int -> end_atom:int -> boundary:Keeper_turn_boundaries.record option -> scope list
(** The selection is already validated by the range owner. Attribute only the
    intersection with the boundary's witnessed admission start. A missing start
    leaves an explicit gap and boundary-only evidence; it never borrows context
    from the last turn for earlier atoms. No I/O. *)
val to_json : t list -> Yojson.Safe.t
