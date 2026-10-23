(** Original host request for completed-history Memory. No explicit-candidate
    queue generation or admission purpose is part of this owner. Blocking
    filesystem operations must be offloaded as a whole from Eio callers. *)
type owner
val observe_owner : base_path:string -> keepers_dir:string -> keeper_id:string ->
  (owner, string) result
(** Descriptor-bound workspace, Memory/config keepers and history runtime/output
    roots, and the existing Memory epoch. Missing epoch
    refuses; initial source capture must first capture the actual program anchor. *)
val discovery_scope : base_path:string -> keepers_dir:string -> keeper_id:string ->
  (string, string) result
(** Physical roots and canonical Keeper only, so a missing/replaced epoch cannot
    hide old originals in a different scope. Addressing grants no authority. *)
val scope : owner -> string
val keeper_id : owner -> string
val base_path : owner -> string
val keepers_dir : owner -> string
val runtime_keepers_dir : owner -> string
val owner_to_json : owner -> Yojson.Safe.t
val owner_matches_json : owner -> Yojson.Safe.t -> (unit, string) result
val fresh_request_id : owner -> string
val scope_of_request_id : string -> (string, string) result
val observe_record_owner : base_path:string -> keepers_dir:string ->
  Lane_addon_tool_request_owner.retained -> (owner, string) result

type destination = {
  installation_id : string;
  package_id : string;
  tool : string;
  source_revision : string;
  configuration_revision : string;
}
val package_id : string
val tool : string
type t
val create : request_id:string -> owner:owner -> destination:destination ->
  source:Keeper_librarian_durable_capture.t ->
  preparation:Keeper_librarian_runtime.durable_preparation -> (t, string) result
(** Full original source/input and immutable Memory preparation must agree.
    Retention/restore performs no provider, Gate, Memory, source or cursor effect. *)
val restore : owner:owner -> Lane_addon_tool_request_owner.retained -> (t, string) result
val to_json : t -> Yojson.Safe.t
val request_id : t -> string
val physical_owner : t -> owner
val destination : t -> destination
val source : t -> Keeper_librarian_durable_capture.t
val preparation : t -> Keeper_librarian_runtime.durable_preparation
val request : t -> (Lane_addon_exact.request, string) result
val confirm_owner : t -> (unit, string) result
val confirm_final : store:Lane_addon_store.t -> t -> Lane_addon_exact.final ->
  (unit, string) result
(** Reobserve full physical owner/epoch, then require the original retained host
    terminal. Each Call_final additionally requires the matching latest completed
    original execution proof/schema/outcome. Worker Finished JSON grants nothing. *)
val validate_proposal : t -> Yojson.Safe.t ->
  (Keeper_librarian_runtime.durable_proposal, string) result

