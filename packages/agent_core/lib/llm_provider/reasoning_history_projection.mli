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
val observe : component:string -> t -> unit
