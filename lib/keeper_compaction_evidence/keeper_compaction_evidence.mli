(** Exact structural evidence for one LLM compaction result. *)
type t =
  { selected_runtime_id : string option
  ; before_checkpoint_bytes : int
  ; after_checkpoint_bytes : int
  ; before_message_count : int
  ; after_message_count : int
  ; summarized_message_count : int
  ; dropped_message_count : int
  ; before_tool_use_count : int
  ; after_tool_use_count : int
  ; before_tool_result_count : int
  ; after_tool_result_count : int
  }

type preserved = private
  { selected_runtime_id : string
  ; checkpoint_bytes : int
  ; message_count : int
  ; tool_use_count : int
  ; tool_result_count : int
  }

type field =
  | Before_checkpoint_bytes
  | After_checkpoint_bytes
  | Before_message_count
  | After_message_count
  | Summarized_message_count
  | Dropped_message_count
  | Before_tool_use_count
  | After_tool_use_count
  | Before_tool_result_count
  | After_tool_result_count

type field_error =
  | Missing
  | Duplicate
  | Expected_integer
  | Negative_integer

type measure =
  | Checkpoint_bytes
  | Messages
  | Tool_uses
  | Tool_results

type decode_error =
  | Expected_object
  | Unknown_field of string
  | Invalid_field of field * field_error
  | Empty_selected_runtime_id
  | Invalid_transition of measure * int * int
  | No_messages_compacted

type preserved_field =
  | Preserved_checkpoint_bytes
  | Preserved_message_count
  | Preserved_tool_use_count
  | Preserved_tool_result_count

type preserved_error =
  | Preserved_expected_object
  | Preserved_unknown_field of string
  | Preserved_invalid_field of preserved_field * field_error
  | Preserved_empty_selected_runtime_id

val to_json : t -> Yojson.Safe.t
(** Structural observation projection of the exact measured counts.
    [selected_runtime_id] remains the enclosing runtime projection. *)

val of_json
  :  selected_runtime_id:string option
  -> Yojson.Safe.t
  -> (t, decode_error) result
(** Restore persisted structural evidence. The Runtime identity is supplied
    from its enclosing typed projection rather than duplicated in the counts
    object. Unknown, duplicate, missing, malformed, or objectively impossible
    evidence is rejected explicitly. [Checkpoint_bytes] must strictly reduce;
    the other measures may stay equal but cannot increase. *)

val preserved
  :  selected_runtime_id:string
  -> checkpoint_bytes:int
  -> message_count:int
  -> tool_use_count:int
  -> tool_result_count:int
  -> (preserved, preserved_error) result
(** Construct evidence for a terminal LLM decision that leaves the exact
    source checkpoint unchanged. One observed value per measure makes a false
    before/after delta unrepresentable. *)

val preserved_to_json : preserved -> Yojson.Safe.t
val preserved_of_json
  :  selected_runtime_id:string
  -> Yojson.Safe.t
  -> (preserved, preserved_error) result
