(** One native Agent API call inside a direct Keeper operation. The seed is
    the exact checkpoint captured after input admission, before effects. *)
type api = New_input of { seed_message_count : int } | Continue_from_checkpoint

type t = private
  { call_id : string
  ; runtime_id : string
  ; operation_digest : string
  ; api : api
  ; seed_checkpoint : Keeper_checkpoint_ref.t
  ; checkpoint : Keeper_checkpoint_ref.t
  ; locator : Agent_core.Agent.execution_locator
  }

type state =
  | No_native_call
  | Active of t
  | Terminal_unacknowledged of t * Agent_core.Agent.execution_terminal_disposition

type history_ref = private
  { call_id : string
  ; runtime_id : string
  ; operation_digest : string
  ; trace_id : Keeper_id.Trace_id.t
  ; locator : Agent_core.Agent.execution_locator
  }
(** Immutable association for reading a native execution after its live state
    has retired. The trace identifies the session directory. No checkpoint,
    terminal decision or dispatch authority is retained by this reference. *)

val history_ref : t -> history_ref
val equal_history_ref : history_ref -> history_ref -> bool
val history_ref_to_json : history_ref -> Yojson.Safe.t
val history_ref_of_json : Yojson.Safe.t -> (history_ref, string) result

type change =
  | Bind of { observed : state; call : t }
  | Checkpoint of { call_id : string; observed : Keeper_checkpoint_ref.t; checkpoint : Keeper_checkpoint_ref.t }
  | Terminal of { call_id : string; disposition : Agent_core.Agent.execution_terminal_disposition }
(** Retirement of a terminal call is not a change here: the Owner's actual
    settlement transaction replaces a Retire receipt with no native call. *)

val transition : state -> change -> (state, string) result

val unknown_effect_disposition : Agent_core.Agent.execution_terminal_disposition
(** How the Owner closes an Active call whose effect it cannot account for:
    cancelled, with an operator repair required, because a tool attempt inside
    it may have run without being settled. *)

val create :
  call_id:string -> runtime_id:string -> operation_digest:string -> api:api ->
  seed_checkpoint:Keeper_checkpoint_ref.t -> locator:Agent_core.Agent.execution_locator ->
  (t, string) result

val advance : t -> observed:Keeper_checkpoint_ref.t -> checkpoint:Keeper_checkpoint_ref.t ->
  (t, string) result
(** Compare the exact previous checkpoint, retaining the immutable seed. *)

val equal : t -> t -> bool
val equal_state : state -> state -> bool
val checkpoint_references : state -> Keeper_checkpoint_ref.t list
val state_to_json : state -> Yojson.Safe.t
val state_of_json : Yojson.Safe.t -> (state, string) result
(** Strict codec. Null means no native call; unknown fields/tags are errors. *)
