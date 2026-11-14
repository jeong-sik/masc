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
val is_scope : string -> bool
val keeper_id : owner -> string
val base_path : owner -> string
val keepers_dir : owner -> string
val runtime_keepers_dir : owner -> string
val owner_to_json : owner -> Yojson.Safe.t
val owner_of_json : Yojson.Safe.t -> (owner, string) result
(** Strict decode of {!owner_to_json}. The owner it names is not observed live;
    {!owner_matches_json} compares it with the live one. *)
val owner_matches_json : owner -> Yojson.Safe.t -> (unit, string) result
val fresh_request_id : owner -> string
val scope_of_request_id : string -> (string, string) result
val minted_on : string -> (string, string) result
(** The UTC day, [YYYY-MM-DD], this history request ID was minted. A finished
    replacement chain settles under the day of its root. *)
val observe_record_owner : base_path:string -> keepers_dir:string ->
  Lane_addon_tool_request_owner.retained -> (owner, string) result

type destination = Lane_addon_captured_destination.t
val package_id : string
val tool : string
val destination_of_json : Yojson.Safe.t -> (destination, string) result
(** Field-exact. Requires a configured installation and this tool's package and tool. *)
type t
type predecessor = {request_id:string;request_digest:string}
val predecessor : t -> predecessor option
val create : ?predecessor:predecessor -> request_id:string -> owner:owner -> destination:destination ->
  source:Keeper_librarian_durable_capture.t ->
  preparation:Keeper_librarian_runtime.durable_preparation -> unit -> (t, string) result
(** Full original source/input and immutable Memory preparation must agree.
    A successor retains its immutable original predecessor ID/digest; its
    complete inventory must establish known basis supersession before dispatch.
    Retention/restore performs no provider, Gate, Memory, source or cursor effect. *)
val restore : owner:owner -> Lane_addon_tool_request_owner.retained -> (t, string) result
val restore_payload : owner:owner -> Lane_addon_tool_request_owner.retained -> (t, string) result
(** Current strict source/preparation/host-binding decode, using only captured
    data. Unlike {!restore}, this does not inspect the live source root. It is
    preflight evidence, never live execution or publication authority. Captured
    source path aliases are preserved; {!restore} separately checks the actual
    canonical path, device and inode against the captured physical owner. *)
val confirm_record : t -> Lane_addon_tool_request_owner.retained -> (unit, string) result
(** The record is this original's: same physical source root and host binding
    as {!restore} checks, and the digest of this request. Equal digests name
    equal canonical requests, so this replaces restoring the record again and
    comparing encodings. Offload the whole call; it reads the source root. *)
type index = private {
  owner : owner;
  destination : destination;
  predecessor : predecessor option;
  runtime_keepers_dir : string;  (** The path {!confirm_index_source_root} observes. *)
  exact_digest : string;  (** [Lane_addon_exact.digest] of {!request}. *)
  source_digest : string;  (** The digest a history fence names the source by. *)
  source_basis_digest : string;
      (** Digest of [Keeper_librarian_durable_capture.basis_json]: equal for an
          original and the child an operator resolution makes of it. *)
}
(** What a reader of the record alone needs of the request. {!index} makes it
    from a verified request and nothing else does; one read from a record
    comes from {!index_of_summary}. *)
val index : t -> (index, string) result
val source_basis_digest : t -> (string, string) result
(** [(index t).source_basis_digest] alone, for a reader that needs no other
    digest of the source. *)
val index_to_json : index -> Yojson.Safe.t
(** The record summary [Keeper_librarian_durable_owner.retain] writes. *)
val index_of_summary : Lane_addon_tool_request_owner.Record.t -> (index, string) result
(** Strict decode of a record's summary. The owner it names addresses the
    record's scope, and its destination is the record's installation, package
    and tool. The other values are bound to the request only where a body is
    read: {!restore_payload} compares them, and compares the two source
    digests for an original with a predecessor; {!confirm_index} compares all
    of them. A summary that is not an index is an error. *)
val confirm_index : t -> Lane_addon_tool_request_owner.Record.t -> (unit, string) result
(** The record's index is exactly {!index} of this request, source digests
    included. *)
val confirm_index_source_root : index -> (unit, string) result
(** What {!restore} adds to {!restore_payload}, from the index: the captured
    runtime path is still the owner's physical runtime root. Offload it. *)
val of_json : owner:owner -> Yojson.Safe.t -> (t, string) result
(** Pure full original-request decoder used for a retained replacement intent.
    This grants no physical-source, retained-owner or dispatch authority. *)
val confirm_predecessor : store:Lane_addon_store.t -> require_confirmed:bool -> t -> (unit, string) result
(** Blocking full parent read and immutable intent check. Retention may accept
    the exact pending intent; dispatch and retained delivery require its ACK.
    Offload the whole call. This performs no publication, ACK or provider work. *)
val validate_predecessor_link_payload :
  read:(scope:string -> request_id:string -> (Lane_addon_tool_request_owner.retained option, string) result) ->
  require_confirmed:bool -> t -> (unit, string) result
(** One existing known-basis link, without traversing ancestors. The history
    resolution lineage reader composes this with its fenced-parent link and
    applies one cycle/ancestry check across both kinds. No effect authority. *)
val validate_predecessor_payload :
  read:(scope:string -> request_id:string -> (Lane_addon_tool_request_owner.retained option, string) result) ->
  require_confirmed:bool -> t -> (unit, string) result
(** Read-only predecessor-chain checks using the same immutable parent state
    and publication intent rules as {!confirm_predecessor}. Restores only
    captured payloads and rejects cycles; does not inspect live source roots. *)
val to_json : t -> Yojson.Safe.t
val request_id : t -> string
val body_digest : t -> string
(** Digest of the verified complete canonical captured request body. *)
val physical_owner : t -> owner
val destination : t -> destination
val source : t -> Keeper_librarian_durable_capture.t
val preparation : t -> Keeper_librarian_runtime.durable_preparation
val request : t -> (Lane_addon_exact.request, string) result
val decode_final : store:Lane_addon_store.t -> t -> Yojson.Safe.t ->
  (Lane_addon_exact.final, string) result
(** Reobserve the original owner and decode with its original host evidence.
    This neither validates the proposal nor grants a Memory write. *)
val confirm_owner : t -> (unit, string) result
val confirm_final : store:Lane_addon_store.t -> t -> Lane_addon_exact.final ->
  (unit, string) result
(** Reobserve full physical owner/epoch, then require the original retained host
    terminal. Each Call_final additionally requires the matching latest completed
    original execution proof/schema/outcome. Worker Finished JSON grants nothing,
    except a final where {!Lane_addon_exact.refused_before_host} holds, for a
    request the host never retained: the worker refuses a request no listing
    reply can carry before the host sees it, and that final holds no answer. *)
val refusal_evidence : store:Lane_addon_store.t -> t -> Lane_addon_exact.final ->
  (Keeper_exact_walk_failure.t, string) result
(** What a refused original shows about reading less. Only an [Input_refused]
    final naming a request body, input capacity or context refusal can show it;
    [Invalid_request] and every other final show nothing. With no host record, the worker's frame refusal
    ([Lane_addon_exact.refused_before_host]) is itself the evidence. With a host
    terminal, the latest completed execution must end in this same final, and
    its receipt supplies the walk's evidence, and only when that evidence is a
    named input refusal with no independent failure mixed in. Anything else, including an open
    host record, shows nothing. Blocking read; offload it in an Eio caller.

    Nothing reads less because of this evidence yet: the Add-on durable path runs with
    [No_message_floor]. The layer that gives that path a floor tests, before it does, that a
    size-refused original descends exactly once and that [Invalid_request] and an open host
    record never descend. *)
val validate_proposal : t -> Yojson.Safe.t ->
  (Keeper_librarian_runtime.durable_proposal, string) result
