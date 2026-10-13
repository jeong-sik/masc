(** Provider-agnostic projection of stored reasoning before request serialization.

    Provider request boundaries pass the complete typed history through this
    module before converting messages to wire JSON. The projection validates
    provenance for the whole history and never infers compatibility from model
    names, endpoint strings, or generated prose. *)

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

type t =
  { messages : Types.message list
  ; reasoning_target : Types.Reasoning_source.t
  ; reasoning_replay_drops : reasoning_replay_drop list
  ; removed_empty_assistant_indices : int list
  }
[@@deriving show]

type error =
  | Invalid_reasoning_target of string
  | Invalid_reasoning_source of
      { message_index : int
      ; classification : Types.Reasoning_source.classification
      }
  | Reasoning_source_on_non_assistant of
      { message_index : int
      ; classification : Types.Reasoning_source.classification
      }
  | Unsupported_reasoning_block of
      { message_index : int
      ; block_index : int
      ; block_kind : reasoning_block_kind
      }
[@@deriving show]

val error_to_string : error -> string

(** [assistant_has_payload] states whether an Assistant message still has a
    representable wire payload after projection. [reasoning_block_supported]
    is the codec's exhaustive declaration of retained reasoning variants.
    [replay_capability] is the one record resolved from the provider config:
    replay target, replay contract, and the declared rotation policy. *)
val project
  :  assistant_has_payload:(Types.content_block list -> bool)
  -> reasoning_block_supported:(Types.content_block -> bool)
  -> replay_capability:Reasoning_dialect.replay_capability
  -> Types.message list
  -> (t, error) result

val project_for_provider_config
  :  assistant_has_payload:(Types.content_block list -> bool)
  -> reasoning_block_supported:(Types.content_block -> bool)
  -> Provider_config.t
  -> Types.message list
  -> (t, error) result

(** Emit bounded aggregate diagnostics. Exact per-message evidence remains in
    the immutable projection value; payload size is independent of history
    length and endpoint URLs are never logged. *)
val observe : component:string -> stream:bool -> t -> unit

(** {1 Creation-prefix binding} *)

type prefix_drop_cause =
  | Prefix_source_not_present
  | Prefix_digest_absent
  | Prefix_request_mismatch
  | Prefix_reasoning_mismatch
[@@deriving show]

type prefix_drop =
  { message_index : int
  ; cause : prefix_drop_cause
  }
[@@deriving show]

type prefix_verify_error =
  | Malformed_prefix_entry of
      { message_index : int
      ; classification : Types.Reasoning_prefix.classification
      }
[@@deriving show]

type prefix_verdict =
  { messages : Types.message list
  ; prefix_drops : prefix_drop list
  ; removed_empty_assistant_indices : int list
  ; final_digest : string
  }
[@@deriving show]

val prefix_verify_error_to_string : prefix_verify_error -> string

(** Wire bytes of one message's content through the caller's encoder, hashed.
    The record side hashes the response content with the same function, so a
    byte edited inside the message fails the comparison below. *)
val content_wire_digest
  :  encode_block:(Types.content_block -> Yojson.Safe.t)
  -> Types.content_block list
  -> string

(** Drop reasoning whose creation prefix cannot be proven identical to the
    current request. A binding wire (Anthropic today) verifies each signed
    thinking block against the system prompt, the tools, the thinking
    controls, and every message before it; replaying one across a rewritten
    prefix fails the whole request with a 400 no retry clears. The fold
    chains a digest over [head] (the request's own head members in wire
    order) and every admitted block, and admits a message's reasoning only
    when the source is present, the recorded request digest equals the chain
    before the message, and the recorded message digest equals
    {!content_wire_digest} of its current content.

    Callers pass post-projection, post-merge messages with the exact encoder
    the wire serializes with; [role_tag] is the wire's role spelling. The
    fold mirrors {!project}: emptied assistants are removed, other roles
    never are. [final_digest] is the chain after the last message — the
    value the record side stamps as the new response's request digest.
    Malformed entries refuse loudly like {!error}; every other doubt drops.
    Dropping stays safe only while the Anthropic branch never emits manual
    [enabled] thinking (which requires the last assistant turn to start with
    a thinking block); revisit this policy the day it does. *)
val verify_prefix_binding
  :  head:(string * Yojson.Safe.t) list
  -> encode_block:(Types.content_block -> Yojson.Safe.t)
  -> role_tag:(Types.role -> string)
  -> Types.message list
  -> (prefix_verdict, prefix_verify_error) result

(** Bounded drop diagnostics in the shape of {!observe}: per-cause counts, a
    bounded sample of dropped indices, and the emptied-assistant count.
    Exact per-message evidence remains in the verdict. *)
val observe_prefix_drops
  :  component:string
  -> stream:bool
  -> prefix_verdict
  -> unit
