(** Trusted host capture for one Curator execution. No worker, provider,
    registry, dispatch or domain commit effects are created here. *)
module Request_id : sig
  type t
  val fresh : unit -> t
  val of_string : string -> (t, string) result
  val to_string : t -> string
end
type workspace
val observe_workspace : base_path:string -> (workspace, string) result
(** Blocking descriptor-bound path/device/inode observation. Run the complete
    scope on a system thread in Eio contexts. Missing/replaced roots are errors.
    A successful observation is not a process lease or permission to execute. *)
type destination = {
  installation_id : string;
  package_id : string;
  tool : string;
  source_revision : string;
  configuration_revision : string;
}
type work = private
  | Classification of { ledger : Workspace_memory_ledger.t; batch : Workspace_memory_request.batch }
  | Briefing of Workspace_memory_briefing.batch
type t
val classification : request_id:Request_id.t -> workspace:workspace -> destination:destination ->
  prompt:Prompt_registry.prompt_resolution -> ledger:Workspace_memory_ledger.t ->
  batch:Workspace_memory_request.batch -> (t, string) result
val briefing : request_id:Request_id.t -> workspace:workspace -> destination:destination ->
  prompt:Prompt_registry.prompt_resolution -> batch:Workspace_memory_briefing.batch -> (t, string) result
(** Check the original whole batch and exact rendered prompt against captured
    template bytes. The original JSON substitution text is retained separately
    because canonical storage can change object key order. Briefing must have
    the same original prompt/schema contract as its prepared pass. Destination
    revisions and prompt resolution must be supplied by the trusted host owner;
    these constructors do not establish their external provenance or ownership. *)
val scope : string
val package_id : string
val tool : string
val request_id : t -> Request_id.t
val predecessor : t -> Request_id.t option
(** None identifies an original root capture. A successor keeps its original
    parent ID; [restore] verifies the complete acknowledged ancestry. *)
val destination : t -> destination
val base_path : t -> string
(** The physically captured workspace path, never today's inferred setting. *)
val work : t -> work
val input_text : t -> string
val rendered_prompt : t -> string
val output_schema : t -> Yojson.Safe.t
val to_json : t -> Yojson.Safe.t
val narrow : request_id:Request_id.t -> final:Lane_addon_exact.final -> t -> (t option, string) result
(** Pure whole-row/whole-entry bisection using the original captured template,
    ledger, physical workspace and destination. Input_capacity, Context_overflow
    and Request_body_refused permit either kind; Output_limit_reached permits
    classification only. Every other terminal is rejected. [Ok None] means one
    indivisible row remains. Does not mint IDs, save state or establish that
    [final] actually belongs to this original request; the host journal does. *)
val restore : workspace:workspace ->
  load:(request_id:string -> (Lane_addon_tool_request_owner.retained option, string) result) ->
  Lane_addon_tool_request_owner.retained -> (t, string) result
(** Restore only from a strict original-owner read. Match the current observed
    physical workspace, original scope/ID/destination and domain schema; verify
    the captured input/template/actual prompt together without reading today's
    prompt override. The caller supplies a fresh observation under its original
    workspace lease/serialization, and still revalidates live authority before
    effects. Strictly load each predecessor; require its matching acknowledged
    child and original typed size refusal, re-derive the entire child capture,
    and reject missing, conflicting, unreadable or cyclic ancestry. A retained
    child whose parent is still Subdividing cannot execute. This is neither
    restart enumeration nor a commit journal. *)
val recoverable_successors : workspace:workspace ->
  Lane_addon_tool_request_owner.retained list -> (string list, string) result
(** Validate the complete freshly discovered original forest before recovery.
    Every capture, physical workspace and whole predecessor/child derivation
    must agree. A Subdividing parent may have no child yet, or exactly its
    initial Captured child with no events; this known publication window is
    validated without granting that child execution authority. An acknowledged
    child must exist. Duplicate, dangling, cyclic or conflicting records reject
    the whole inventory, including malformed unrelated members.
    Return only parent IDs with already durable successor intentions. No new
    ID, intent, admission, worker call or domain effect is authorized. Caller
    must re-read each parent under the original lease/serializer and perform
    ordinary full restore after recovering its exact existing intention. *)
type expected_commit =
  | Classification_commit of Workspace_memory_ledger.t
  | Briefing_commit of Workspace_memory_briefing.t
val validate_output : t -> Yojson.Safe.t -> (expected_commit, string) result
(** Original pure full-domain decision validation and expected state only.
    Does not save, publish, mark an observer complete or authorize a retry. *)
val commit_plan : t -> judgment:Yojson.Safe.t ->
  (expected_commit * Lane_addon_request_progress.change, string) result
(** Strict original Answered final, full domain validation and exact before/after
    plan. Shared by settlement and observation; no current domain read or write. *)
