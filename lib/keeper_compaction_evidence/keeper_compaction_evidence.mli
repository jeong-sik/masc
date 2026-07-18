(** Exact structural evidence for one LLM compaction result. *)
type t =
  private
  { selected_runtime_id : string option
  ; before_checkpoint_bytes : int
  ; after_checkpoint_bytes : int
  ; before_message_count : int
  ; after_message_count : int
  ; summarized_message_count : int
  ; dropped_message_count : int
  ; pair_repair_dropped_message_count : int
  ; before_tool_use_count : int
  ; after_tool_use_count : int
  ; before_tool_result_count : int
  ; after_tool_result_count : int
  }

type field =
  | Before_checkpoint_bytes
  | After_checkpoint_bytes
  | Before_message_count
  | After_message_count
  | Summarized_message_count
  | Dropped_message_count
  | Pair_repair_dropped_message_count
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
  | Invalid_message_accounting of
      { before_message_count : int
      ; after_message_count : int
      ; summarized_message_count : int
      ; dropped_message_count : int
      ; pair_repair_dropped_message_count : int
      }
  | Legacy_message_accounting_not_derivable of
      { before_message_count : int
      ; after_message_count : int
      ; summarized_message_count : int
      ; dropped_message_count : int
      }
  | No_messages_compacted

val decode_error_to_string : decode_error -> string
val wire_field_names : string list
(** Canonical JSON field names for public projection and closed decoding. *)

val exact_evidence_key : string
(** JSON envelope key under which a manifest decision payload carries the
    [to_json] evidence object. Writers, the manifest projection allowlist,
    and dashboard readers spell the key through this constant. *)

val create
  :  selected_runtime_id:string option
  -> before_checkpoint_bytes:int
  -> after_checkpoint_bytes:int
  -> before_message_count:int
  -> after_message_count:int
  -> summarized_message_count:int
  -> dropped_message_count:int
  -> pair_repair_dropped_message_count:int
  -> before_tool_use_count:int
  -> after_tool_use_count:int
  -> before_tool_result_count:int
  -> after_tool_result_count:int
  -> (t, decode_error) result
(** Construct evidence through the same closed validation boundary used by
    persisted JSON restoration. Message accounting is exact:
    [after = before - dropped - summarized + summary_message
     - pair_repair_dropped], where [summary_message] is one exactly when
    [summarized] is non-zero. *)

val to_json : t -> Yojson.Safe.t
(** Structural observation projection of the exact measured counts.
    [selected_runtime_id] remains the enclosing runtime projection. *)

val of_json
  :  selected_runtime_id:string option
  -> Yojson.Safe.t
  -> (t, decode_error) result
(** Restore persisted structural evidence. The Runtime identity is supplied
    from its enclosing typed projection rather than duplicated in the counts
    object. Rows written before [pair_repair_dropped_message_count] was added
    are migrated by deriving that count exactly from the other message counts;
    an impossible derivation is rejected. Other unknown, duplicate, missing,
    malformed, or objectively impossible evidence is rejected explicitly.
    [Checkpoint_bytes] must strictly reduce; the other measures may stay equal
    but cannot increase. *)
