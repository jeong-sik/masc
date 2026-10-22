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
val request_id : t -> Request_id.t
val destination : t -> destination
val work : t -> work
val input_text : t -> string
val rendered_prompt : t -> string
val output_schema : t -> Yojson.Safe.t
val to_json : t -> Yojson.Safe.t
val restore : workspace:workspace -> Lane_addon_tool_request_owner.retained -> (t, string) result
(** Restore only from a strict original-owner read. Match the current observed
    physical workspace, original scope/ID/destination and domain schema; verify
    the captured input/template/actual prompt together without reading today's
    prompt override. The caller supplies a fresh observation under its original
    workspace lease/serialization, and still revalidates live authority before
    effects. This is neither restart enumeration nor a commit journal. *)
type expected_commit =
  | Classification_commit of Workspace_memory_ledger.t
  | Briefing_commit of Workspace_memory_briefing.t
val validate_output : t -> Yojson.Safe.t -> (expected_commit, string) result
(** Original pure full-domain decision validation and expected state only.
    Does not save, publish, mark an observer complete or authorize a retry. *)
