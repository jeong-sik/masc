(** Provider-agnostic projection of stored reasoning before request serialization.

    Provider request boundaries pass the complete typed history through this
    module before converting messages to wire JSON. The projection validates
    provenance for the whole history and never infers compatibility from model
    names, endpoint strings, or generated prose. Declared control lowering runs
    before replay selection; diagnostic indices retain canonical source
    coordinates even when controls consolidate into one System frame. *)

type reasoning_replay_drop_reason =
  | Replay_policy_excluded of Reasoning_replay_contract.replay_policy
  | Missing_reasoning_source
  | Incompatible_reasoning_source of Types.Reasoning_source.t
  | Reasoning_on_non_assistant
[@@deriving show]

type reasoning_replay_drop =
  { message_index : int
  ; reason : reasoning_replay_drop_reason
  }
[@@deriving show]

type reasoning_block_kind =
  | Thinking_block
  | Reasoning_details_block
  | Redacted_thinking_block
[@@deriving show]

(** The projection is the same over any media source: it reads block
    kinds, roles and metadata, never media. *)
type 'source projection =
  { messages : 'source Types.message_with list
  ; reasoning_target : Types.Reasoning_source.t
  ; reasoning_replay_drops : reasoning_replay_drop list
  ; removed_empty_assistant_indices : int list
  }
[@@deriving show]

type t = Types.media_source projection [@@deriving show]

type error =
  | Invalid_control_lowering of Message_origin_lowering.error
  | Invalid_reasoning_target of string
  | Invalid_reasoning_source of
      { message_index : int
      ; classification : Types.Reasoning_source.classification
      }
  | Reasoning_source_on_non_assistant of
      { message_index : int
      ; classification : Types.Reasoning_source.classification
      }
  | Invalid_response_replay of { message_index : int; detail : string }
  | Unbound_reasoning_artifact of { message_index : int }
  | Incompatible_reasoning_artifact of
      { message_index : int
      ; stored : Types.Reasoning_source.t
      ; target : Types.Reasoning_source.t
      }
  | Invalid_reasoning_artifact_role of { message_index : int }
  | Unsupported_reasoning_block of
      { message_index : int
      ; block_index : int
      ; block_kind : reasoning_block_kind
      }
[@@deriving show]

val error_to_string : error -> string

type source_change_policy =
  | Reject_incompatible
  | Exclude_unselected
(** Caller-owned admission policy. [Exclude_unselected] admits foreign
    reasoning only when the target dialect does not select it for replay.
    Missing/corrupt provenance is never admitted by this policy. *)

type continuity_boundary =
  | Checkpoint_restore
  | Provider_dispatch of { tools_present : bool }
(** Restoration precedes caller input: opt-in source changes are provisional
    there. Dispatch checks the final query boundary and actual prepared tools
    after input and hooks. The caller must identify which boundary it owns. *)

type replay_disposition =
  | Preserve_reasoning
  | Caller_excluded_reasoning
  | Source_change_admitted of reasoning_replay_drop list
  (** Pending compatibility at restoration; actual wire exclusions at dispatch.
      Each entry retains its canonical message index and original producer. *)

type replay_continuity_admission =
  { capability : Reasoning_dialect.replay_capability
  ; disposition : replay_disposition
  }

val validate_replay_continuity_for_provider_config
  :  ?source_change_policy:source_change_policy
  -> boundary:continuity_boundary
  -> Provider_config.t
  -> 'source Types.message_with list
  -> (replay_continuity_admission, error) result
(** Validate canonical history and admit its stored reasoning producers before
    restoring a provider-bound Agent and again before dispatch after hooks and
    caller input projection. Uses the target's declared rotation rule,
    including every reasoning-bearing message and validated inline Chat carrier
    in mixed-producer history. A
    target that cannot replay the old source is rejected by default.
    [Exclude_unselected] returns the incompatible indices/producers in the
    disposition. At [Checkpoint_restore] this is provisional admission only;
    at [Provider_dispatch] each must be outside the target's
    replay selection. Opaque state and selected foreign reasoning remain errors.
    The dispatch tools fact must match the actual request, including hook edits
    and temporary tool suppression. It is not inferred from the model catalog.
    When no caller query survives projection, latest-turn tool exchanges are
    conservatively selected: absent boundary evidence cannot authorize their
    exclusion. Compatible reasoning remains replayable under the same rule.
    The same policy must be supplied at resume and dispatch.
    Explicit [preserve_thinking = Some false] admits caller-owned exclusion only
    when the resolved dialect actually declares [No_replay]. A wire that ignores
    that knob cannot pretend to exclude replay. This decision is independent of
    temporary tool-array suppression. Structure is validated in either case.
    Returns the resolved capability and the boundary-specific admission disposition.
    Never projects or mutates the history. It reads block kinds, roles and
    metadata only, so it takes history and provider messages alike and never
    reads media. *)

(** [assistant_has_payload] states whether an Assistant message still has a
    representable wire payload after projection. [reasoning_block_supported]
    is the codec's exhaustive declaration of retained reasoning variants.
    [replay_capability] is the one record resolved from the provider config:
    replay target, replay contract, and the declared rotation policy. *)
val project
  :  ?control_lowering:Message_origin_lowering.policy
  -> assistant_has_payload:('source Types.content_block_with list -> bool)
  -> reasoning_block_supported:('source Types.content_block_with -> bool)
  -> replay_capability:Reasoning_dialect.replay_capability
  -> 'source Types.message_with list
  -> ('source projection, error) result

val project_for_provider_config
  :  ?tools_present:bool
  -> assistant_has_payload:('source Types.content_block_with list -> bool)
  -> reasoning_block_supported:('source Types.content_block_with -> bool)
  -> Provider_config.t
  -> 'source Types.message_with list
  -> ('source projection, error) result

(** Emit bounded aggregate diagnostics. Exact per-message evidence remains in
    the immutable projection value; payload size is independent of history
    length and endpoint URLs are never logged. *)
val observe : component:string -> stream:bool -> t -> unit

(** {1 Creation-prefix binding} *)

(** Why one message's reasoning was removed before serialization. Every cause
    fails closed: the block is not sent and the turn proceeds without it.
    - [Prefix_entry_invalid] and [Prefix_entry_duplicate]: the stored digest tag
      cannot be read. They name corrupted history, not a changed request.
    - [Prefix_request_mismatch]: the request digest differs from the chain and
      no earlier drop in this request could have changed the chain.
    - [Prefix_chain_broken_upstream]: the same mismatch after an earlier drop
      that could have changed the chain. Blocks that carried no readable stamp
      ([Prefix_source_not_present], [Prefix_digest_absent]) were never sent, so
      dropping them again explains nothing about a later mismatch. Later
      digests were stamped over the history with a stamped block present, so a
      mismatch after one is not an independent finding. *)
type prefix_drop_cause =
  | Prefix_source_not_present
  | Prefix_digest_absent
  | Prefix_entry_invalid
  | Prefix_entry_duplicate
  | Prefix_request_mismatch
  | Prefix_chain_broken_upstream
  | Prefix_reasoning_mismatch
[@@deriving show]

(** [stored_message_digest] is the message digest read from the stored tag.
    It is [Some] only for the three causes decided after the tag parsed
    ([Prefix_request_mismatch], [Prefix_chain_broken_upstream],
    [Prefix_reasoning_mismatch]). *)
type prefix_drop =
  { message_index : int
  ; cause : prefix_drop_cause
  ; stored_message_digest : string option
  }
[@@deriving show]

(** [reasoning_message_count] is the number of messages that carried reasoning
    when they entered the fold; each drop removes one of them. *)
type prefix_verdict =
  { messages : Types.message list
  ; prefix_drops : prefix_drop list
  ; removed_empty_assistant_indices : int list
  ; reasoning_message_count : int
  ; final_digest : string
  }
[@@deriving show]

(** Wire bytes of one message's content through the caller's encoder, hashed.
    The record side hashes the response content with the same function, so a
    byte edited inside the message fails the comparison below. *)
val content_wire_digest
  :  encode_block:(Types.content_block -> Yojson.Safe.t)
  -> Types.content_block list
  -> string

(** Drop reasoning whose creation prefix cannot be proven identical to the
    current request. A binding wire (Anthropic today) verifies each signed
    thinking block against the system prompt, the tools, and every message
    before it — exactly the fields the API's own prefix check covers;
    replaying one across a rewritten prefix fails the whole request with a
    400 no retry clears. The fold chains a digest over [head] (the
    API-checked head members in wire order) and every admitted block, and
    admits a message's reasoning only
    when the source is present, the recorded request digest equals the chain
    before the message, and the recorded message digest equals
    {!content_wire_digest} of its current content.

    Callers pass post-projection, post-merge messages with the exact encoder
    the wire serializes with; [message_header] contains the exact native role and semantic message
    fields such as clear_at, excluding cache markers. The
    fold mirrors {!project}: emptied assistants are removed, other roles
    never are. [final_digest] is the chain after the last message — the
    value the record side stamps as the new response's request digest.
    An unreadable tag (invalid or duplicated) drops the message's reasoning
    with its own cause instead of failing the request: the tag sits in the
    stored history, so a failure would repeat on every request while the
    message stays in the window. Every doubt drops.
    Dropping stays safe only while the Anthropic branch never emits manual
    [enabled] thinking (which requires the last assistant turn to start with
    a thinking block); revisit this policy the day it does. *)
val verify_prefix_binding
  :  head:(string * Yojson.Safe.t) list
  -> encode_block:(Types.content_block -> Yojson.Safe.t)
  -> message_header:(Types.message -> (string * Yojson.Safe.t) list)
  -> Types.message list
  -> prefix_verdict

(** The fields of the per-request snapshot {!observe_prefix_drops} logs:
    messages entering the fold with reasoning, replayed and dropped, a count
    per cause, and a bounded sample of dropped blocks named by the first 12 hex
    characters of their stored message digest. It reads one request, not an
    event count: a stale block is dropped again by every request that still
    carries it, so the number of distinct blocks cut is a query over
    [dropped_block_ids]. *)
val prefix_snapshot_json
  :  component:string
  -> stream:bool
  -> prefix_verdict
  -> Yojson.Safe.t

(** Logs {!prefix_snapshot_json} when the request dropped reasoning or removed
    an emptied assistant. The line is Warn when a stored tag was unreadable
    and Info otherwise. Exact per-message evidence remains in the verdict. *)
val observe_prefix_drops
  :  component:string
  -> stream:bool
  -> prefix_verdict
  -> unit
