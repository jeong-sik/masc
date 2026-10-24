type replay_policy =
  | No_replay
  | Tool_call_assistant_messages_all_history
  | Tool_call_assistant_messages_latest_user_turn
  | All_assistant_messages
  | Provider_opaque_state
[@@deriving show, eq, yojson]

type output_wire =
  | No_output_control
  | Reasoning_split
[@@deriving show, eq, yojson]

type streaming_reasoning =
  | No_streaming_reasoning
  | Delta_field of string
  | Delta_field_and_details of string
  | Template_parser
[@@deriving show, eq, yojson]

(* Declared decision for prior-turn reasoning whose recorded source differs
   from the source the next request targets (endpoint rotation, model swap,
   provider change). This replaces an incidental [stored <> target] inequality
   with a named rule, so a continuity drop is a policy outcome rather than a
   side effect of comparing hashes. It is deliberately NOT a field of {!t}:
   rotation is the consuming request's decision, while {!t} describes the
   persisted artifact's producing semantics. *)
type rotation_policy =
  | Require_identical_source
  | Allow_endpoint_rotation
[@@deriving show, eq, yojson]

type content_carrier = Canonical_blocks | Inline_chat_content
[@@deriving show, eq, yojson]

type t =
  { replay_policy : replay_policy
  ; streaming : streaming_reasoning
  ; output_wire : output_wire
  ; content_carrier : content_carrier
  }
[@@deriving show, eq, yojson]
