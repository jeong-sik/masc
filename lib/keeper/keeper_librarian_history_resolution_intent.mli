(** One original's durable resolution requests. Submission identity is the
    canonical original/guard/actor/reason digest; old refusals remain readable.
    At most one non-refused request and one child intent own an original. *)
type refusal = Observation_changed | No_longer_eligible of string
type child = private { request_id:string; request_digest:string }
type phase = Requested | Refused of refusal | Fenced
  | Child_intended of child | Child_confirmed of child
type memory_commit = private {
  request_id:string;
  receipts:Keeper_memory_os_current_types.durable_range_receipt list;
}
type t = private {
  intent_id:string;
  scope:string;
  original_request_id:string;
  expected:Keeper_librarian_history_resolution_state.guard;
  actor:string;
  reason:string;
  submitted_at:float;
  phase:phase;
  memory_commit:memory_commit option;
}
type error = Invalid of string | Conflict of string | Unavailable of string
  | Publication_uncertain of string
val error_to_string : error -> string
val to_public_json : t -> Yojson.Safe.t
(** Contains no original body, preimage or child request body. *)
val decode_published : scope:string -> request_id:string -> Yojson.Safe.t ->
  (t list, string) result
(** Pure strict envelope decoder for the deployment preflight's owned bytes. *)
val check_published_file : group:string -> name:string -> Yojson.Safe.t -> (unit, string) result
(** What a pass does with one file of a scope's resolution directory, for the
    deployment preflight: [group] is the directory's name, [name] the file's.
    A pass decodes every file there, whether or not its original still has a
    record. *)
val submit : config:Workspace.config -> keeper_name:string -> request_id:string ->
  expected:Keeper_librarian_history_resolution_state.guard -> actor:string ->
  reason:string -> now:float -> (t * bool, error) result
(** The bool is true for an existing identical submission. This only persists
    the intent; no scheduling or Memory effect. Changed payloads refuse while
    active or fenced. A pre-fence refusal permits a new guard, preserving both.
    A post-fence refusal terminates only the continuation; its immutable fence
    remains and a changed submission for that original is still refused. *)
val read : config:Workspace.config -> keeper_name:string -> request_id:string ->
  (t list, error) result
val active_for_keeper : config:Workspace.config -> keeper_name:string ->
  (t list, error) result
(** Strict complete scope inventory. Any unreadable intent prevents new work. *)
val reload : store:Lane_addon_store.t -> t -> (t, error) result
val refuse : store:Lane_addon_store.t -> expected:t -> refusal -> (t, error) result
(** Requested may be refused; Fenced may only be refused as No_longer_eligible
    before any child intent, after confirming the same durable fence. No fence,
    source cursor or Memory receipt is removed or acknowledged. *)
val confirm_fence : store:Lane_addon_store.t -> expected:t ->
  Keeper_librarian_history_resolution_state.t -> (t, error) result
val intend_child : store:Lane_addon_store.t -> expected:t ->
  Keeper_librarian_durable_request.t -> (t, error) result
val confirm_child : store:Lane_addon_store.t -> expected:t ->
  Lane_addon_tool_request_owner.Record.t -> (t, error) result
val observe_memory_commit : store:Lane_addon_store.t -> expected:t ->
  request:Keeper_librarian_durable_request.t ->
  completed:Lane_addon_tool_request_owner.retained -> (t, error) result
(** Serialized Memory-lane use only. Confirm exact current committed range
    receipts under Memory locks without recovery, then retain that observation.
    A missing/pending/uncertain receipt does not establish completion.
    When [request] is a replacement that descends from the resolution child,
    the child is read as its record and index, not its body: the caller has
    confirmed [request]'s lineage, which restores that child. *)
val child : t -> child option
(** The child a [Child_intended] or [Child_confirmed] intent names by ID and
    digest. The intent holds no request: the child's request is the body file
    its digest names, staged before the intent and read where it is used. *)
