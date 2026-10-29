(** Request-only lowering of typed controls at provider boundaries.
    Canonical messages are never mutated. No source is inferred from text. *)

type policy =
  | Preserve_positions
  | Turn_scoped_system_context
  | Initial_system_native_tools
  | Initial_system_tool_response_media

type error =
  | Unsupported_codec
  | Missing_caller_query
  | Invalid_control_role of { message_index : int; role : Types.role }
  | Non_text_control of { message_index : int }
  | Invalid_system_frame
  | Invalid_user_frame
  | Context_must_follow_user of { message_index : int }
  | Context_must_precede_assistant of { message_index : int }
[@@deriving show]

val error_to_string : error -> string

val policy_for_provider_config : Provider_config.t -> (policy, error) result

type 'source lowered =
  { messages : 'source Types.message_with list
  ; source_indices : int list
    (** One canonical source coordinate per lowered message. The consolidated
        System frame names its first contributing occurrence; other messages
        retain their exact occurrence coordinates. *)
  }

(** Lowering reads roles, origins and block kinds, never media. *)
type t = Types.media_source lowered

(** [Turn_scoped_system_context] preserves context positions/content, lowers
    typed current/historical context to native System, and requires a text-only
    group after a native user and before an assistant or request end.

    Initial-system policies consolidate controls into a single initial frame. Fresh system context and
    agent instructions are active. Historical system context is quoted data;
    a recovery instruction is active only after both the latest Conversation User
    and the latest assistant response.
    Plain System messages remain system instructions. A template request needs
    an actual caller query; controls never manufacture one.

    Native Ollama tool images belong to ToolResult. A synthetic native media
    followup has no owning result identity and is rejected, not guessed. *)
val lower : policy -> 'source Types.message_with list -> ('source lowered, error) result

(** Quote ordinary caller text as a JSON string at the wire boundary, so a
    caller cannot collide with the template's reserved tool_response syntax.
    Media parts retain their native shape. Encode a true typed tool-media followup using the template's tool_response
    protocol. This runs after tool-result media projection and modality ordering
    so the protocol delimiters enclose the actual emitted media parts. *)
val encode_user_boundary
  :  policy
  -> message:Types.message
  -> Yojson.Safe.t list
  -> (Yojson.Safe.t list, error) result

(** Add the configured system prompt, combining it with the consolidated first
    System frame for initial-system templates. Payloads must come from the
    native/OAI Chat serializer, whose System content is a scalar string. *)
val prepend_system_prompt
  :  policy
  -> system_prompt:string option
  -> Yojson.Safe.t list
  -> (Yojson.Safe.t list, error) result

(** Native Messages header, shared by serialization and creation-prefix hashing.
    Dynamic current/historical context has identical role/clear_at encoding. *)
val anthropic_message_header : policy -> Types.message -> (string * Yojson.Safe.t) list

val is_turn_scoped_context : policy -> Types.message -> bool

(** Validate the exact post-projection/post-prefix transcript again, since a
    removed empty assistant can otherwise invalidate System placement. *)
val validate_turn_scoped_contexts : policy -> Types.message list -> (unit, error) result
