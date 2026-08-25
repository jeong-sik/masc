(** Single source of truth for the public read-only execution projection. *)

module type S = sig
  module type ID = sig
    type t

    val to_string : t -> string
    val equal : t -> t -> bool
    val compare : t -> t -> int
    val pp : Format.formatter -> t -> unit
  end

  module Event_id : ID
  module Run_id : ID
  module Node_id : ID
  module Correlation_id : ID

  type output_block_kind =
    | Text_block
    | Thinking_block
    | Reasoning_details_block
    | Redacted_thinking_block
    | Image_block
    | Document_block
    | Audio_block

  type node_kind =
    | Agent_run of { agent_name : string }
    | Agent_turn of { ordinal : int }
    | Provider_attempt of
        { ordinal : int
        ; target : Binding_identity.Redacted_snapshot.t
        }
    | Output_block of
        { ordinal : int
        ; block_kind : output_block_kind
        }
    | Tool_invocation of
        { provider_tool_use_id : string option
        ; tool_name : string
        ; schedule : Tool_contract.schedule
        ; completion : Tool_contract.completion
        }
    | Tool_attempt

  type node = private
    { node_id : Node_id.t
    ; run_id : Run_id.t
    ; parent_node_id : Node_id.t option
    ; kind : node_kind
    }

  type node_update =
    | Provider_event of Yojson.Safe.t
    | Provider_response_snapshot of Llm_provider.Types.api_response
    | Output_delta of Yojson.Safe.t
    | Output_snapshot of Llm_provider.Types.content_block
    | Tool_input_delta of Yojson.Safe.t
    | Tool_input_snapshot of Llm_provider.Types.content_block
    | Tool_progress of Yojson.Safe.t
    | Tool_result of Llm_provider.Types.content_block

  type failure_kind =
    | Provider_failure
    | Tool_failure
    | Hook_failure
    | Observer_failure
    | Persistence_failure
    | Protocol_failure
    | Internal_failure

  type failure =
    { kind : failure_kind
    ; detail : string
    ; data : Yojson.Safe.t option
    }

  type terminal =
    | Succeeded
    | Failed of failure
    | Cancelled of
        { reason : string option
        ; data : Yojson.Safe.t option
        }

  type payload =
    | Node_opened of node
    | Node_updated of
        { node_id : Node_id.t
        ; update : node_update
        }
    | Node_closed of
        { node_id : Node_id.t
        ; terminal : terminal
        }

  module External_source : sig
    type t

    val of_string : string -> (t, string) result
    val to_string : t -> string
    val equal : t -> t -> bool
    val compare : t -> t -> int
    val pp : Format.formatter -> t -> unit
  end

  type cause =
    | Internal_event of Event_id.t
    | External_event of
        { source : External_source.t
        ; event_id : string
        }

  type event = private
    { event_id : Event_id.t
    ; run_id : Run_id.t
    ; correlation_id : Correlation_id.t
    ; seq : int
    ; parent_event_id : Event_id.t option
    ; causes : cause list
    ; payload : payload
    ; event_time : float
    ; observed_at : float
    ; source_clock : Event_envelope.source_clock
    }

  type cursor

  type cursor_field =
    | Version
    | Scope_id
    | Sequence

  type cursor_decode_error =
    | Cursor_not_object
    | Missing_cursor_field of cursor_field
    | Unexpected_cursor_field of string
    | Duplicate_cursor_field of cursor_field
    | Invalid_cursor_field of
        { field : cursor_field
        ; detail : string
        }
    | Unsupported_cursor_version of
        { expected : int
        ; actual : int
        }

  val cursor_to_yojson : cursor -> Yojson.Safe.t
  val cursor_of_yojson : Yojson.Safe.t -> (cursor, cursor_decode_error) result
  val cursor_decode_error_to_string : cursor_decode_error -> string
  val cursor_seq : cursor -> int

  type unexpected_store_error =
    | Writer_already_active
    | Store_already_attached
    | Store_released
    | Store_release_forbidden
    | Resource_cleanup_failed
    | Construction_cleanup_failed
    | Store_already_exists
    | Correlation_mismatch
    | Sequence_conflict
    | Committed_content_conflict
    | Cursor_scope_mismatch
    | Cursor_ahead
    | Store_poisoned
    | Commit_outcome_unknown

  type storage_failure =
    | Invalid_store_argument of string
    | Store_identity_failure of string
    | Store_io_failure of
        { operation : string
        ; detail : string
        }
    | Store_codec_failure of string
    | Store_not_found
    | Store_initialization_incomplete
    | Store_initialization_conflict
    | Unsupported_store_version of
        { expected : int
        ; actual : int
        }
    | Corrupt_store of
        { offset : int64
        ; detail : string
        }
    | Commit_authority_identity_changed
    | Commit_authority_regressed of
        { previous_committed_offset : int64
        ; actual_committed_offset : int64
        ; previous_last_seq : int
        ; actual_last_seq : int
        }
    | Unexpected_store_failure of
        { kind : unexpected_store_error
        ; detail : string
        }

  type cursor_role =
    | After
    | Through

  type error =
    | Invalid_limit of int
    | Cursor_scope_mismatch
    | Cursor_ahead of
        { cursor_role : cursor_role
        ; cursor_seq : int
        ; high_watermark : int
        }
    | Locator_not_found of Run_id.t
    | Locator_not_top_level of Run_id.t
    | Semantic_failure of
        { seq : int
        ; detail : string
        }
    | Storage_failure of storage_failure

  val error_to_string : error -> string

  type page = private
    { events : event list
    ; next_cursor : cursor
    ; high_watermark : cursor
    ; has_more : bool
    }

  type t

  val beginning_cursor : t -> cursor
  val current_cursor : t -> (cursor, error) result

  (** Read at most [limit] events strictly after [after]. Without [through], the
      current atomic authority is observed before the page is selected. Reusing
      a returned [high_watermark] as [through] freezes later pages to that exact
      committed prefix. [limit] is a transport boundary only. *)
  val read_page
    :  t
    -> after:cursor
    -> ?through:cursor
    -> limit:int
    -> unit
    -> (page, error) result
end
