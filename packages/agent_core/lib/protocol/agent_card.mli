(** Agent Card — self-describing metadata for agent capability negotiation.

    Inspired by the A2A (Agent-to-Agent) protocol.

    @stability Internal
    @since 0.93.1 *)

(** {1 Capability} *)

type capability =
  | Tools
  | Streaming
  | Thinking
  | StructuredOutput
  | Handoff
  | Checkpoint
  | MCP
  | Elicitation
  (** The agent has at least one caller-owned elicitation boundary: generic
      before-turn input, exact pre-tool approval, or both. This capability does
      not promise remote prompting, suspension, timeout enforcement, or
      restart-resumable pending state. *)
  | Custom_cap of string
[@@deriving yojson, show]

val capability_to_string : capability -> string
val capability_of_string : string -> capability

(** {1 Agent Card} *)

type credential_ref =
  | Env of string
  | File of string
  | No_credential

type authentication =
  { schemes : string list
  ; credential_ref : credential_ref
  }

type supported_interface = private
  { url : string
  ; protocol_binding : string
  ; protocol_version : string
  ; tenant : string option
  }

(** A caller-owned, non-empty collection of validated interfaces. *)
type supported_interfaces

val create_supported_interface
  :  url:string
  -> protocol_binding:string
  -> protocol_version:string
  -> ?tenant:string
  -> unit
  -> (supported_interface, Error.sdk_error) result

val supported_interfaces
  :  supported_interface
  -> supported_interface list
  -> supported_interfaces

val supported_interfaces_of_list
  :  supported_interface list
  -> (supported_interfaces, Error.sdk_error) result

val supported_interfaces_to_list : supported_interfaces -> supported_interface list

type skill_meta =
  { name : string
  ; description : string option
  }
[@@deriving show]

type agent_card =
  { name : string
  ; description : string option
  ; version : string
  ; authentication : authentication option
  ; supported_interfaces : supported_interfaces
  ; capabilities : capability list
  ; tools : Types.tool_schema list
  ; skills : skill_meta list
  ; supported_providers : string list
  ; metadata : (string * Yojson.Safe.t) list
  }

(** {1 Serialization} *)

val to_json : agent_card -> Yojson.Safe.t
val of_json : Yojson.Safe.t -> (agent_card, Error.sdk_error) result

(** {1 Construction from agent info} *)

type agent_info =
  { agent_name : string
  ; agent_description : string option
  ; version : string
  ; config : Types.agent_config
  ; tool_schemas : Types.tool_schema list
  ; supported_providers : string list
    (** Exact provider identities declared by the caller. An empty list stays
        empty; construction never invents a default provider. *)
  ; mcp_clients_count : int
  ; has_elicitation : bool
    (** [true] for generic elicitation, exact tool approval, or both. *)
  ; skills : skill_meta list
  ; supported_interfaces : supported_interfaces
    (** Exact caller-owned interface authority. Construction cannot synthesize
        a default URL, binding, or protocol version. *)
  }

val of_info : agent_info -> agent_card

(** {1 Queries} *)

val has_capability : agent_card -> capability -> bool
val can_handle_tool : agent_card -> string -> bool
val has_skill : agent_card -> string -> bool
