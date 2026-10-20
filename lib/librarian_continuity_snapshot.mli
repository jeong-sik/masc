(** Working state paired with exact conversation coverage and explicit unread
    source messages. Coverage certifies representation except for those holes. This value codec
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
  ; unread_messages : Keeper_librarian_unread.t list
      (** Exact messages below [end_atom] that this state does not represent. *)
  ; catch_up_end_atom : int option
      (** Set on a snapshot the Librarian is rewriting from atom 0: where a
          request starts without it, as of the round that wrote it -- the
          Librarian's durable position when it fits the history, else the
          end of the last completed turn. The snapshot does not stand for the
          history until its end reaches that start, so a rewrite never moves a
          request's start back (RFC keeper-context-window-in-tokens §13.4).
          Always past [end_atom]; [None] once a round's end reaches it, and
          the key is absent from the JSON then. *)
  }

type error =
  | Invalid_snapshot of string
  | Uncovered_history
      (** No line of the current generation of this trace states where the
          history ends: no end line carries an atom position and no
          official-client turn started from it, or the witnessed range does
          not begin at a restart. *)
  | Unmatched_history
      (** The current generation of this trace has atom-bearing end lines,
          and none of them matches the history in hand. Where that history
          was completed is unknown; it is not the start. *)
  | Range_stopped of Keeper_librarian_range.stop
  | Trace_mismatch
  | History_changed
  | Prefix_changed
  | Read_failed of string
  | Write_failed of string

(** The hash state of [prefix_sha256] over the atoms before one end of one
    message list, kept with the very message values it read. Given back to
    {!restore} or {!capture_checkpoint_prefix} with a later end over those
    same values, physically, it is extended by the atoms after its end; with
    any other list it is ignored and the whole prefix is read again. *)
type prefix_digest

type restored =
  { working_state : string
  ; unread_messages : Keeper_librarian_unread.t list
  ; messages : Agent_core.Types.message list
  ; covered_prefix : prefix_digest
      (** The verified [prefix_sha256] state over [messages] in hand at
          [end_atom], for a capture of the same values to extend. *)
  }

val capture
  :  unread_messages:Keeper_librarian_unread.t list
  -> trace_id:string
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

val capture_checkpoint_prefix : ?prefix:prefix_digest -> ?end_atom:int ->
  unread_messages:Keeper_librarian_unread.t list ->
  catch_up_end_atom:int option -> trace_id:string ->
  lines:(int * (Keeper_turn_boundaries.record, Keeper_turn_boundaries.read_error) result) list ->
  messages:Agent_core.Types.message list -> working_state:string -> unit -> (t, error) result
(** Explicitly capture the supplied prefix through a whole atom, covered by a
    real completed boundary. No synthetic restart or progress is introduced.
    [catch_up_end_atom] is the rewrite's catch-up target ({!t}); one the
    captured end already reached is dropped. [prefix] is a {!prefix_digest}
    of these message values the digest may extend instead of reading the
    whole prefix again. *)

val restore
  :  ?prefix:prefix_digest
  -> trace_id:string
  -> lines:(int * (Keeper_turn_boundaries.record, Keeper_turn_boundaries.read_error) result) list
  -> messages:Agent_core.Types.message list
  -> t
  -> (restored, error) result
(** Validate the same history generation, exact ending boundary and turn, and every covered message, then retain
    pinned messages and atoms at or after the exclusive end. Appends are allowed. A [prefix] over these same
    message values spares encoding the covered messages it already fed; the decision is the same without it. *)

val to_json : t -> Yojson.Safe.t
val of_json : Yojson.Safe.t -> (t, error) result
(** Schema version 2, field-exact; unversioned or other versions are rejected.
    An empty hole list must be explicit. No unread source or cause is defaulted. *)
val save : path:string -> t -> (unit, error) result
val load : path:string -> (t, error) result
val error_to_string : error -> string
