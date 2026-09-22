(** Working state paired with exact conversation coverage. This value codec
    and projection do not choose a storage path or change a progress cursor. *)
type origin = Witnessed_history | Captured_checkpoint_prefix

type t = private
  { origin : origin
  ; covering_end_atom : int
      (** Real completed boundary covering the saved prefix; may exceed the cut. *)
  ; covering_last_atom_digest : string
  ; trace_id : string
  ; history_start_boundary_line : int
  ; end_boundary_line : int
      (** Exact boundary-log row covering the captured prefix. *)
  ; end_turn_ref : Ids.Turn_ref.t
      (** Typed turn identity on that row; equal message bytes alone do not
          establish that the boundary is the same. *)
  ; end_atom : int
  ; last_atom_digest : string
  ; prefix_sha256 : string
  ; working_state : string
  }

type error =
  | Invalid_snapshot of string
  | Uncovered_history
  | Range_stopped of Keeper_librarian_range.stop
  | Trace_mismatch
  | History_changed
  | Prefix_changed
  | Read_failed of string
  | Write_failed of string

type restored =
  { working_state : string
  ; messages : Agent_core.Types.message list
  }

val capture
  :  trace_id:string
  -> lines:(int * (Keeper_turn_boundaries.record, Keeper_turn_boundaries.read_error) result) list
  -> messages:Agent_core.Types.message list
  -> working_state:string
  -> (t, error) result
(** Covers only a completed range beginning at a witnessed restart. A baseline
    does not prove that its preceding history was represented. *)

val checkpoint_prefix_range : trace_id:string ->
  lines:(int * (Keeper_turn_boundaries.record, Keeper_turn_boundaries.read_error) result) list ->
  messages:Agent_core.Types.message list -> (Keeper_librarian_range.range, error) result
(** Actual completed checkpoint prefix, including history predating the log.
    This is source selection, never evidence of a Memory read or cursor move. *)

val capture_checkpoint_prefix : ?end_atom:int -> trace_id:string ->
  lines:(int * (Keeper_turn_boundaries.record, Keeper_turn_boundaries.read_error) result) list ->
  messages:Agent_core.Types.message list -> working_state:string -> unit -> (t, error) result
(** Explicitly capture the supplied prefix through a whole atom, covered by a
    real completed boundary. No synthetic restart or progress is introduced. *)

val restore
  :  trace_id:string
  -> lines:(int * (Keeper_turn_boundaries.record, Keeper_turn_boundaries.read_error) result) list
  -> messages:Agent_core.Types.message list
  -> t
  -> (restored, error) result
(** Validate the same history generation, exact ending boundary and turn, and every covered message, then retain
    pinned messages and atoms at or after the exclusive end. Appends are allowed. *)

val to_json : t -> Yojson.Safe.t
val of_json : Yojson.Safe.t -> (t, error) result
val save : path:string -> t -> (unit, error) result
val load : path:string -> (t, error) result
val error_to_string : error -> string
