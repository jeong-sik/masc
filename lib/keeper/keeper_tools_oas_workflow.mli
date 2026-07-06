(** Pure workflow rejection logic.

    No mutable state.  All functions are deterministic.

    @since P2 extraction *)

(** Whether a workflow rejection should block the same task/action scope
    before execution. Missing policy is deliberately observe-only. *)
type workflow_rejection_scope_policy =
  | Observe_scope
  (** Legacy diagnostic value accepted for compatibility with older
      payloads. Runtime scope blocking is not driven by this field. *)
  | Block_scope

val workflow_rejection_scope_policy_to_string :
  workflow_rejection_scope_policy -> string

val workflow_rejection_scope_policy_of_string :
  string -> workflow_rejection_scope_policy option

(** Structured info extracted from a workflow-rejection tool result. *)
type workflow_rejection_info =
  { task_id : string option
  ; rule_id : string option
  ; tool_suggestion : string option
  ; alternatives : string list
  ; hint : string option
  ; scope_policy : workflow_rejection_scope_policy
  }

(** Typed [error_class] values carried by a workflow rejection. Unknown
    strings stay data, but never imply deterministic retry-skip. *)
type workflow_rejection_error_class =
  | Workflow_error_deterministic
  | Workflow_error_transient
  | Workflow_error_other of string

(** Typed recoverability marker carried by a workflow rejection. Missing
    recoverability is observe-only. *)
type workflow_rejection_recoverability =
  | Workflow_recoverable
  | Workflow_unrecoverable

(** Retry policy derived from explicit workflow rejection fields. *)
type workflow_rejection_retry_policy =
  | Workflow_retry_observe
  | Workflow_retry_skip_deterministic

(** Structured workflow-rejection payload extracted from JSON. *)
type workflow_rejection_payload =
  { info : workflow_rejection_info
  ; error_class : workflow_rejection_error_class option
  ; recoverability : workflow_rejection_recoverability option
  }

(** Parse source for workflow-rejection JSON decode failures. *)
type workflow_rejection_parse_source =
  | Workflow_rejection_raw
  | Workflow_rejection_error_field

type workflow_rejection_parse_error =
  | Workflow_rejection_json_parse_error of
      { source : workflow_rejection_parse_source
      ; message : string
      }

val workflow_rejection_parse_error_to_string :
  workflow_rejection_parse_error -> string

(** Extract [workflow_rejection_payload] from parsed JSON, preserving malformed
    nested JSON payload errors. *)
val workflow_rejection_payload_of_json_result
  :  Yojson.Safe.t
  -> (workflow_rejection_payload option, workflow_rejection_parse_error) result

(** Compatibility option wrapper for {!workflow_rejection_payload_of_json_result}.
    Parse failures are logged before returning [None]. *)
val workflow_rejection_payload_of_json
  :  Yojson.Safe.t
  -> workflow_rejection_payload option

(** Derive the retry policy. Only explicit deterministic +
    unrecoverable payloads can skip retry. *)
val workflow_rejection_retry_policy
  :  workflow_rejection_payload
  -> workflow_rejection_retry_policy

val workflow_rejection_should_skip_retry : workflow_rejection_payload -> bool

(** Build a workflow-rejection payload with typed retry-policy fields.

    [extra_fields] (RFC-0109 Phase D) attaches optional key/value pairs
    to the top-level JSON object (e.g. [cdal_verdict_payload] with
    typed findings). Empty list (default) preserves the legacy shape. *)
val workflow_rejection_payload_json
  :  ?rule_id:string
  -> ?tool_suggestion:string
  -> ?hint:string
  -> ?scope_policy:workflow_rejection_scope_policy
  -> ?alternatives:string list
  -> ?extra_fields:(string * Yojson.Safe.t) list
  -> error_class:workflow_rejection_error_class
  -> recoverability:workflow_rejection_recoverability
  -> string
  -> string
(** [alternatives] is the typed list of tool names the caller can use
    instead.  RFC-0195 P0: surface a typed [alternatives] field on
    every workflow_rejection emit so the LLM receives concrete next-
    tool candidates rather than parsing prose hints.  Empty list (default)
    omits the field entirely; existing callers that omit this argument
    are unaffected. *)

(** Extract [workflow_rejection_info] from a raw JSON string, preserving JSON
    decode failures. Plain non-JSON strings are [Ok None]. *)
val workflow_rejection_info_of_raw_result
  :  string
  -> (workflow_rejection_info option, workflow_rejection_parse_error) result

(** Compatibility option wrapper for {!workflow_rejection_info_of_raw_result}.
    Parse failures are logged before returning [None]. *)
val workflow_rejection_info_of_raw : string -> workflow_rejection_info option

(** Build a stable family key for deduplication. *)
val workflow_rejection_family_key
  :  tool_name:string
  -> workflow_rejection_info
  -> string

(** Human-readable recovery instruction. *)
val workflow_rejection_recovery_instruction
  :  tool_name:string
  -> count:int
  -> workflow_rejection_info
  -> string

(** Build recovery fields for insertion into the tool-result JSON. *)
val workflow_rejection_recovery_fields
  :  tool_name:string
  -> count:int
  -> string
  -> (string * Yojson.Safe.t) list

(** Extract a non-empty string value from JSON. *)
val json_nonempty_string_opt : string -> Yojson.Safe.t -> string option

(** Check if handoff_context has non-empty evidence_refs. *)
val json_has_nonempty_evidence_refs : Yojson.Safe.t -> bool

(** Build a workflow-submit evidence marker string. *)
val workflow_submit_evidence_marker : Yojson.Safe.t -> string
