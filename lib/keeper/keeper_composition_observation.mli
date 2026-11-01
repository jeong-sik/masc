(** Read-only projection of the existing nested execution result. No prepared
    definition or invocation artifact is treated as execution completion. *)
type admission =
  | Not_attempted
  | Recorded of { tool_use_id : string; frame_sha256 : string }
  | Rejected of Yojson.Safe.t
type node_origin = Arguments | Submission | Result | Child_node of string
type node =
  { node_id : string
  ; origin : node_origin
  ; disposition : (unit, unit, unit) Tool_result.disposition option
  ; tool_use_id : string option
  ; effect_disposition : Tool_result.failure_effect_disposition option
  ; validation_error : Yojson.Safe.t option
  }
type export_value = Available of Yojson.Safe.t | Unavailable of Yojson.Safe.t
type export = { name : string; node_id : string; pointer : string; value : export_value }
type child =
  { alias : string
  ; reference : Skill_reference.t
  ; execution : Keeper_tool_composition_catalog.execution_mode
  ; arguments : Yojson.Safe.t
  ; admission : admission
  ; disposition : Keeper_composition_nested_run.disposition
  ; cause : Yojson.Safe.t option
  ; nodes : node list
  ; exports : export list
  }
type reading = Absent | Observed of child list | Stored of Tool_output.artifact_ref | Invalid of string
val of_data : Yojson.Safe.t -> reading
(** Direct canonical async result data or an exact structured-result envelope.
    Only the reserved root metadata is read; user output is not searched. *)
val of_content : string -> reading
(** Complete original ToolResult bytes, never a ledger preview. A manifest
    marker stays [Stored] until its exact bytes have been retrieved. *)
val of_blob_response : Tool_output.artifact_ref -> Yojson.Safe.t -> reading
(** Validate response identity, media type, byte count, SHA256 and the existing
    manifest grammar before projecting its structured content. *)
