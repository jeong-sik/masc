(** Private evidence from an actual structured-response parser failure.
    Raw output and parser details use the Agent Core evidence bound. They are
    written only to the workspace's private trace store; public errors carry
    the closed failure class and a reference to the committed record. *)

type source = Vision | Fusion_judge

type attempt =
  { source : source
  ; invocation_id : Shared_types.Artifact_id.t
  ; runtime_id : string
  ; attempt_index : int
  ; tool_use_id : string option
  ; trace_id : string option
  }

val invocation_id : unit -> Shared_types.Artifact_id.t
(** Identifies one parser-owner invocation, not an SDK run or provider request. *)

val record_failure :
  base_path:string option -> attempt:attempt -> Agent_core.Error.t -> string
(** Called only after the actual candidate returned invalid structured output.
    A canonical parse error keeps its original bounded preview and byte count.
    Other errors retain the existing [Agent_core.Error.to_string] rendering
    and do not create response evidence.

    Canonical structured parse errors return a public-safe detail. A reference
    is included only after the private 0600 JSONL append commits. Missing workspace or failed
    storage is explicitly unavailable; the original parse failure remains a
    failure. Cancellation propagates. No provider request or retry is made. *)

val record_path : base_path:string -> Shared_types.Artifact_id.t -> string
(** Exact operator file coordinate, under [.masc/traces/structured-output/].
    This is local private evidence, not a public artifact-download capability. *)
