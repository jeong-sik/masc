(** Immutable transient plans bound to the preparing Keeper's frozen surface.
    Shared Skill publication is independent of this execution draft. *)

type t
type authored_source = private
  { package_id : Skill_reference.package_id
  ; source_text : string
  }

type error =
  | Plan_rejected of Keeper_tool_plan_request.error
  | Inputs_rejected of Keeper_tool_plan.Node_id.t * Keeper_tool_plan.execution_error
  | Unsupported_node of { node_id : Keeper_tool_plan.Node_id.t; tool_name : string }
  | Storage_failed of string
  | Draft_read_failed of Tool_blob_store.fetch_error
  | Draft_not_found
  | Malformed_draft of string
  | Different_keeper
  | Capability_changed
  | Publication_rejected of Keeper_skill_catalog.authored_source_error
  | Skill_not_prepared
  | Different_package
  | Nested_rejected of Keeper_composition_nested.error
  | Nested_publication_requires_catalog

val prepare_tool_name : string
val run_tool_name : string
val error_to_json : error -> Yojson.Safe.t
val failure_class : error -> Tool_result.tool_failure_class
val prepare_schema : Masc_domain.tool_schema
val run_schema : Masc_domain.tool_schema

val without_recursive_refs : Yojson.Safe.t -> Yojson.Safe.t
(** Replace any JSON object whose ["$ref"] field is ["#/$defs/template"] with
    the non-recursive placeholder object, regardless of sibling keywords or
    field order, and drop ["$defs"]. *)

val prepare
  :  base_path:string
  -> capability_surface:Keeper_capability_surface.t
  -> keeper_name:string
  -> execution:Keeper_tool_composition_catalog.execution_mode
  -> Yojson.Safe.t
  -> (t, error) result
(** Compile ordinary nodes or exact frozen inline child Skill references,
    preflight every fixed argument/input, and durably store the original recipe,
    flattened plan, child provenance, owner, execution mode and contracts.
    Inline leaves may also use the canonical owned-file Edit producer. Durable
    async leaves carry a static read-only contract or the isolated owned-job
    launch producer's durable Serial effect contract. Child definitions
    are inline; ordinary and nested drafts support both execution modes. Async
    runs persist original child activation authority before worker admission.
    Named nested publication remains a separate contract. *)
(* Optional [skill] metadata freezes [package_id] and [description] into a
   validated SKILL.md using an ordinary parameter-free plan. No publication
   occurs. A task-only draft need not carry reusable Skill metadata. *)

val load
  :  base_path:string
  -> capability_surface:Keeper_capability_surface.t
  -> keeper_name:string
  -> sha256:string
  -> (t, error) result
(** Integrity-check the prepared artifact and revalidate all current contracts
    and inputs before effects. A changed owner/surface/schema is a rejection,
    not a rebind of the old preview. *)

val prepare_request
  :  base_path:string
  -> capability_surface:Keeper_capability_surface.t
  -> keeper_name:string
  -> Yojson.Safe.t
  -> (t, error) result
(** Validate the public prepare grammar, including execution mode, and freeze
    the draft without dispatching or activating any node. *)

val resolve_run_request
  :  base_path:string
  -> capability_surface:Keeper_capability_surface.t
  -> keeper_name:string
  -> Yojson.Safe.t
  -> (t, error) result
(** Resolve exactly one public run source: load the referenced frozen draft,
    or prepare and durably freeze a supplied [recipe] using [prepare_request].
    A recipe is a fresh invocation and cannot carry [resume_run_id]. This
    function never dispatches nodes; the caller must record the original run
    invocation before entering the ordinary executor. *)

val load_continuation
  :  base_path:string
  -> capability_surface:Keeper_capability_surface.t
  -> Keeper_tool_execution_journal.continuation
  -> (t, error) result
(** Load only the original artifact sealed into an owned waiting continuation.
    Recompile the exact original recipe against current admission and compare
    every frozen node route/input/output contract and fixed input. Unrelated
    current surface changes do not replace the preparing surface evidence or
    invalidate unchanged admitted nodes. Ordinary [load] and publication still
    require the exact whole surface. This does not reserve a worker; the caller
    must bind this same sealed continuation before effects. *)

type continuation_refusal = Current_tool_denied of
  { node_id : Keeper_tool_plan.Node_id.t; tool_name : string }
type continuation_admission = Admitted of t | Refused of t * continuation_refusal
val continuation_refusal_to_json : continuation_refusal -> Yojson.Safe.t
val load_continuation_admission : base_path:string ->
  capability_surface:Keeper_capability_surface.t ->
  Keeper_tool_execution_journal.continuation -> (continuation_admission, error) result
(** Explicit Tool denial can return a fully revalidated original draft, including
    its exact nested child contracts and mappings, only as [Refused]. Missing or
    corrupt evidence, unavailable child references and changed contracts stay Error.
    Ordinary [load]/[load_continuation] never admit denied descriptors. *)

val plan : t -> Keeper_tool_plan.t
val nested_calls : t -> Keeper_composition_nested.call list
(** Exact frozen child references, fixed arguments, leaf and export mappings.
    These describe prepared scopes, not dispatched Skill activations. *)
val execution : t -> Keeper_tool_composition_catalog.execution_mode
val reference : t -> Tool_output.artifact_ref
val authored_source : t -> authored_source option
val load_authored
  :  base_path:string
  -> capability_surface:Keeper_capability_surface.t
  -> keeper_name:string
  -> package_id:Skill_reference.package_id
  -> sha256:string
  -> (authored_source, error) result
(** Load only the exact Skill source frozen in this owned draft. A task-only
    draft or a different package identity is refused before publication. *)
val preview : t -> Yojson.Safe.t
(** Immutable draft metadata, including dependencies, exports and authored
    source references. The public composition prepare boundary adds its
    [schedule_preview] through {!Keeper_composition_draft_preview.preview}. *)

val record_invocation
  :  base_path:string
  -> ?nested_activation:Keeper_skill_activation_recorder.bound_context
  -> composition_run_id:Keeper_tool_plan.Composition_run_id.t
  -> invocation:Agent_core.Tool_contract.Invocation.t
  -> t
  -> (Tool_output.artifact_ref, error) result
(** Persist the draft and source invocation binding before dispatch. This
    records one attempted run and does not execute or replay any plan node.
    The caller passes this same [composition_run_id] to the executor and
    observers, so the durable binding and actual leaf invocations identify
    one attempted run. *)

val load_nested_activation : base_path:string ->
  Keeper_tool_execution_journal.source ->
  (Keeper_skill_activation_recorder.bound_context option, error) result
(** Strictly read the original owned run artifact, including exact draft,
    invocation and child mappings. Restore the sealed original recorder facts;
    ordinary runs carry null. No activation or worker is created. *)

val load_nested_result_children : base_path:string ->
  Keeper_tool_execution_journal.source -> result:Yojson.Safe.t ->
  ((Keeper_skill_activation_recorder.bound_context *
    Keeper_skill_activation_recorder.result_child list) option, error) result
(** Restore only admitted child receipts whose complete result scope matches
    the exact frozen run call. Strictly decode each original activation and its
    immutable frame digest; the recorder then compares that frame with the
    original ledger. Do not infer admission from success text or outputs. *)
