(** Private current-row wire contract. Storage and schema use the same
    generation; unknown or inconsistent rows produce typed quarantine. *)

type stimulus_kind =
  | Board_signal
  | Bootstrap
  | Fusion_completed  (* RFC-0266: async masc_fusion completion wake *)
  | Schedule_due  (* Scheduled automation due wake for a specific keeper *)
  | Connector_attention
      (* RFC-connector-ambient-attention-wake: ambient connector message wake *)
  | Hitl_resolved  (* HITL resolution delivered as an ordinary Keeper wake *)
  | Ask_answered  (* A human answered a question this Keeper asked *)
  | Completion_authority_rejected
  | Task_outcome  (* The approval twin of Completion_authority_rejected *)
  | Task_cancelled
  | Workspace_message
  | Delegate_completed  (* One Keeper's answer to a turn another asked it to run *)
  | Composition_completed  (* An async composition this Keeper submitted has settled *)

type reaction_kind =
  | Turn_started
  | Turn_finished
  | Event_queue_ack
  | Event_queue_cancelled

type reaction_decode_error = Unknown_reaction_kind of string

val storage_generation : string
val schema : string
val digest_id : string -> string -> string
val stimulus_kind_to_string : stimulus_kind -> string
val stimulus_kind_of_string : string -> stimulus_kind option
val reaction_kind_to_string : reaction_kind -> string
val reaction_kind_of_string : string -> (reaction_kind, reaction_decode_error) result

type transition_source =
  { stimulus_id : string
  ; post_id : string
  ; stimulus_kind : stimulus_kind
  }

val event_queue_transition_event_id :
  Keeper_event_queue_state.transition_receipt -> int -> string

val assoc_field : string -> Yojson.Safe.t -> Yojson.Safe.t option
val string_field : string -> Yojson.Safe.t -> string option
val float_field : string -> Yojson.Safe.t -> float option
val int_field : string -> Yojson.Safe.t -> int
val list_field : string -> Yojson.Safe.t -> Yojson.Safe.t list

type row_quarantine_reason =
  | Malformed_json_row
  | Missing_schema
  | Unexpected_schema
  | Missing_event_id
  | Empty_event_id
  | Missing_keeper_name
  | Empty_keeper_name
  | Keeper_name_mismatch
  | Missing_recorded_at
  | Non_finite_recorded_at
  | Missing_stimulus_id
  | Empty_stimulus_id
  | Missing_record_kind
  | Unknown_record_kind
  | Missing_stimulus
  | Missing_stimulus_kind
  | Unknown_stimulus_kind
  | Missing_stimulus_source
  | Unknown_stimulus_source
  | Missing_stimulus_post_id
  | Missing_stimulus_urgency
  | Unknown_stimulus_urgency
  | Missing_stimulus_arrived_at
  | Non_finite_stimulus_arrived_at
  | Missing_reaction
  | Missing_reaction_kind
  | Quarantine_unknown_reaction_kind
  | Missing_reaction_source
  | Unknown_reaction_source
  | Reaction_source_mismatch
  | Missing_reaction_post_id
  | Missing_reaction_stimulus_kind
  | Unknown_reaction_stimulus_kind
  | Missing_transition_receipt
  | Invalid_transition_receipt
  | Missing_transition_source_index
  | Missing_transition_source_count
  | Invalid_transition_source_count
  | Missing_transition_source
  | Invalid_transition_source
  | Transition_source_index_out_of_bounds
  | Transition_source_identity_mismatch
  | Event_identity_mismatch
  | Transition_kind_mismatch
  | Non_finite_board_updated_at

val row_quarantine_reason_to_string : row_quarantine_reason -> string

type current_row_metadata =
  { event_id : string
  ; stimulus_id : string
  ; recorded_at : float
  ; raw : Yojson.Safe.t
  }

type current_row =
  | Current_stimulus of
      { metadata : current_row_metadata
      ; stimulus_kind : stimulus_kind
      }
  | Current_reaction of
      { metadata : current_row_metadata
      ; reaction_kind : reaction_kind
      ; transition_receipt : Keeper_event_queue_state.transition_receipt option
      }

val decode_current_row :
  keeper_name:string -> Yojson.Safe.t -> (current_row, row_quarantine_reason) result
