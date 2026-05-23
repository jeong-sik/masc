(* Autonomous_executor — Cycle 27 / Tier W1. *)

type tool_call = {
  name : string;
  args : Yojson.Safe.t;
}

val prefix_of : string -> string option

val classify_tool : string -> Multimodal.Artifact.tag option

val payload_of_args : Yojson.Safe.t -> Multimodal.Payload.t

val metadata_of_call : string -> Yojson.Safe.t -> Yojson.Safe.t

val provenance_for :
  now:float -> created_by:string -> Multimodal.Artifact.provenance

val translate :
  tool_call -> now:float -> created_by:string -> Multimodal.Artifact.any option

val accumulate :
  Multimodal.Workspace.t ->
  tool_call list ->
  now:float ->
  created_by:string ->
  Multimodal.Workspace.t * Multimodal.Artifact.any list
