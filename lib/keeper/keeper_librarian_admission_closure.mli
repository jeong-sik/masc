(** One host-owned closing transaction for an admission forest. The producer
    holds the workspace lease, Memory lane and purge fence. These operations
    never dispatch, write Memory or acknowledge queue candidates. *)
type kind = Part | Partition | Execution | Gate
type stage = Captured | Closing | Closed
type t
type member
val scope : Keeper_librarian_admission_capture.owner -> string
val is_scope : string -> bool
val restore : owner:Keeper_librarian_admission_capture.owner ->
  Lane_addon_tool_request_owner.retained -> (t, string) result
val stage : t -> stage
val candidates : t -> Keeper_memory_os_current.explicit_candidate_id list
val members : t -> member list
val member_record : member -> Lane_addon_tool_request_owner.Record.t
val date : t -> string
val record : t -> Lane_addon_tool_request_owner.retained
val named_ids : t -> string list
(** Complete typed archive references for the existing sweep. *)
val retain : store:Lane_addon_store.t -> owner:Keeper_librarian_admission_capture.owner ->
  request_id:string -> candidates:Keeper_memory_os_current.explicit_candidate_id list ->
  originals:(kind * Lane_addon_tool_request_owner.retained) list -> (t, string) result
(** Retain a Captured manifest only. Caller has strictly validated the complete
    four scopes, all partitions and full normal frontier, exact receipts for
    every original candidate and queue ACK absence. Large execution bodies are
    not copied. No member moves, and this alone grants no closing authority. *)
val intend : store:Lane_addon_store.t -> t -> (t, string) result
(** Publish the first three host journal events atomically, after the producer
    freshly reconfirms the complete eligibility contract above. Publication
    uncertainty requires reloading the same manifest; no replacement ID. *)
val confirm : store:Lane_addon_store.t -> t -> (t, string) result
(** Record the exact after-state only after every member's original settle,
    including body cleanup, completed. The caller must check that state. *)

type reader = scope:string -> request_id:string ->
  (Lane_addon_tool_request_owner.retained option, string) result
type scope_reader = scope:string -> (Lane_addon_tool_request_owner.retained list, string) result
type body_reader = scope:string -> request_digest:string -> (Yojson.Safe.t, string) result
type archive_reader = scope:string -> date:string -> request_id:string ->
  (Lane_addon_tool_request_owner.Record.t option, string) result
type view = {
  closure : t option;
  read : reader;
  read_scope : scope_reader;
  read_body : body_reader;
  live_members : Lane_addon_tool_request_owner.retained list;
}
val project : owner:Keeper_librarian_admission_capture.owner -> read:reader ->
  read_scope:scope_reader -> read_body:body_reader -> read_archive:archive_reader ->
  (view, string) result
(** Read-only current payload view. A missing small member is restored only
    from the manifest's exact payload after its complete archived metadata
    matches. Missing execution bodies are never reconstructed. Every actual
    read still checks present records and complete inventories, including
    unexpected members. A Captured transaction permits no missing member;
    live gates require all execution parents still live. No Current or domain
    authority is reachable here. Validate remaining payloads with the current
    consumer decoders before recovery or reporting compatibility. *)
