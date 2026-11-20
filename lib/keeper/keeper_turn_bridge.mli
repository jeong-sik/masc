(** Causal turn bridging across runtime switches (Agent Core <-> Official
    subscription clients, and Official client A <-> B resumes).

    Official-client turns keep their canonical [No_atom_history] boundary
    records and fragment files without inventing synthetic Agent-Core
    checkpoints, while retaining cross-runtime continuity in two ways:
    - {!uncheckpointed_official_turns} projects any trailing official-client
      turns since the last checkpointed boundary (deduplicated by turn ref
      metadata) so Agent Core and fresh official-client starts see prior
      official-client conversation without changing official-client atom
      semantics.
    - {!record_official_client_settlement} and
      {!intervening_context_for_official_resume} track durable boundary cursors
      per [(client_kind, runtime_id, session_id)] so resuming a retained native
      session after intervening turns on any other runtime injects only the
      intervening turns that session has not yet witnessed. *)

(** Metadata key stamped on bridged [Agent_core.Types.message] values so
    stage-saved checkpoints never duplicate an already bridged turn. *)
val bridged_turn_ref_metadata_key : string

(** Extract the bridged turn reference stamped on [msg], if any. Pure. *)
val bridged_turn_ref_of_message : Agent_core.Types.message -> Ids.Turn_ref.t option

type bridge_load_error =
  | Boundary_log_unreadable of string
  | Boundary_line_unreadable of
      { line : int
      ; error : Keeper_turn_boundaries.read_error
      }
  | Fragment_store_unreadable of
      { trace_id : string
      ; file : Keeper_turn_fragments.file
      ; detail : string
      }
  | Fragment_line_unreadable of
      { trace_id : string
      ; file : Keeper_turn_fragments.file
      ; line : int
      ; error : Keeper_turn_fragments.read_error
      }
  | Cursor_store_invalid of string

val bridge_load_error_to_string : bridge_load_error -> string

(** Project trailing uncheckpointed [No_atom_history] turns of [trace_id]
    since the latest checkpointed atom boundary or trace history restart,
    excluding any turns whose reference is already present on
    [existing_messages]. Read-only. *)
val uncheckpointed_official_turns
  :  keepers_dir:string
  -> keeper_name:string
  -> trace_id:string
  -> session_dir:string
  -> existing_messages:Agent_core.Types.message list
  -> (Agent_core.Types.message list, bridge_load_error) result

(** Record the turn-boundary cursor settled by [(client_kind, runtime_id,
    session_id)] once its [Turn_ended] line is durable. Fails closed on
    corrupt cursor payloads without inventing defaults. *)
val record_official_client_settlement
  :  base_path:string
  -> keeper_name:string
  -> turn_ref:Ids.Turn_ref.t
  -> client_kind:Keeper_semantic_execution.official_client_kind
  -> runtime_id:string
  -> session_id:string
  -> updated_at:float
  -> (unit, string) result

(** Render intervening completed turns of [trace_id] recorded after the last
    boundary cursor settled by [(client_kind, runtime_id, session_id)]. Returns
    [Ok None] when the session has no prior cursor or no intervening turns.
    Read-only: never advances cursors before dispatch settles. *)
val intervening_context_for_official_resume
  :  base_path:string
  -> keeper_name:string
  -> trace_id:string
  -> client_kind:Keeper_semantic_execution.official_client_kind
  -> runtime_id:string
  -> session_id:string
  -> (string option, bridge_load_error) result

(** Convenience wrapper for official-client adapters entering [Resume]:
    when [input_source] carries a [trace_id], prepends any intervening context
    returned by {!intervening_context_for_official_resume} ahead of [goal];
    logs a warning and returns [goal] unchanged if the bridge store fails. *)
val prepend_resume_handoff
  :  input_source:Keeper_request_source.t
  -> base_path:string
  -> keeper_name:string
  -> client_kind:Keeper_semantic_execution.official_client_kind
  -> runtime_id:string
  -> session_id:string
  -> goal:string
  -> string
