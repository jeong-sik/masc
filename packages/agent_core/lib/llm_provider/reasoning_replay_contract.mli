(** Typed compatibility contract for replaying a stored reasoning artifact.

    This leaf vocabulary is shared by the reasoning dialect resolver and the
    persisted reasoning source. It deliberately contains no provider names or
    model matching rules. *)

type replay_policy =
  | No_replay
  | Tool_call_assistant_messages_all_history
  | Tool_call_assistant_messages_latest_user_turn
  (** Replay reasoning only from assistant tool-call messages that occur after
      the structurally latest [User] role. With no [User] role, replay none. *)
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
  | Delta_reasoning_details
  | Template_parser
[@@deriving show, eq, yojson]

(** Declared decision for prior-turn reasoning whose recorded source differs
    from the source the next request targets. Resolved once per request from
    the typed dialect and carried in the replay capability record; consumers
    never compare source identities on their own terms.

    This type is intentionally not a member of {!t}: {!t} is serialized into
    the persisted reasoning-source stamp, so adding a field would make every
    previously stored artifact fail to parse. *)
type rotation_policy =
  | Require_identical_source
  (** The artifact is bound to the exact producing source: it carries a
      signature the endpoint validates, or it is a handle to state the provider
      holds. Any difference in provider kind, endpoint instance, model, or
      replay contract drops it. *)
  | Allow_endpoint_rotation
  (** The artifact is self-contained reasoning text with no producer-bound
      token. It survives a base URL / request path rotation of the same
      provider kind, canonical model, and replay contract; every other
      difference still drops it. *)
[@@deriving show, eq, yojson]

type t =
  { replay_policy : replay_policy
  ; streaming : streaming_reasoning
  ; output_wire : output_wire
  }
[@@deriving show, eq, yojson]
