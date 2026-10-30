(** Host-to-worker control envelope. This travels on an unexported control tool,
    never in the model's arguments. It is trusted only on the host-owned stdio
    connection, not as an authentication scheme for a public worker endpoint. *)
type principal = Keeper of string | Authenticated_agent of string | Host_actor of string | Operator | Anonymous
(** [Host_actor] is identity admitted by a host HTTP authorization boundary,
    including explicitly allowed token-less local attribution. It conveys no
    Keeper-private installation access. *)
type companion = private { socket_path:string; invocation_id:string; max_message_bytes:int;
  publication_id:string option }
val companion_to_json : companion -> Yojson.Safe.t
val companion_of_json : Yojson.Safe.t -> (companion, string) result
(** Private invocation capabilities. [publication_id=None] explicitly has no
    automatic continuation destination. Never retain or expose these through
    model tools; publication and Browser admission have independent lifetimes. *)
type t = private { tool : string; arguments : Yojson.Safe.t; principal : principal;
  controller : Machine_controller_contract.admission option; companion:companion option }
val tool_name : string
val to_json_with_controller : controller:Machine_controller_contract.admission option ->
  companion:companion option -> tool:string -> arguments:Yojson.Safe.t -> principal:principal -> Yojson.Safe.t
val to_json : tool:string -> arguments:Yojson.Safe.t -> principal:principal -> Yojson.Safe.t
val of_json : Yojson.Safe.t -> (t, string) result
val input_schema : Yojson.Safe.t
val actor_label : principal -> string
(** Distinct provenance labels; these are not host account identifiers. *)

(** {1 Observation effects}

    What a call to an exported tool can do to the worker's last observation,
    in the worker's own words on the private [effects_tool] port. MCP
    [readOnlyHint] is a different promise: it says a tool does not modify its
    environment, and a tool can keep that promise while its call still changes
    what the next observation shows. *)
type observation_effect =
  | Reads_only  (** the last observation still shows the worker after the call *)
  | May_change  (** the call may change what the next observation shows *)

val effects_tool : string
(** The private port when explicitly opted into and not already named as an
    action or export. It takes no arguments and answers {!effects_to_json}. *)

val effects_input_schema : Yojson.Safe.t
(** Empty arguments with a namespaced, versioned opt-in annotation. *)
val supports_effects_tool : Yojson.Safe.t -> bool
(** Whether the input schema contains exactly one supported opt-in marker. *)

val effects_to_json : (string * observation_effect) list -> Yojson.Safe.t
(** [{"tools": {"<tool name>": "reads_only" | "may_change", ...}}]. *)

val effects_of_json : listed:string list -> Yojson.Safe.t ->
  ((string * observation_effect) list, string) result
(** Reads a declaration. A value other than the two names, a tool missing from
    [listed] (the worker's own tools/list), a tool named twice or any other
    shape is an [Error]. A tool left out is not in the result. *)

type host_refusal = Rejected of string | Unavailable of string
  | Activity_disabled of string | Activity_unobserved of string
type invocation_error = Host_refusal of host_refusal | Transport_error of string

(** Host mediation obtains credential admission before any worker RPC mutex.
    Each RPC is serialized independently. Keep admission through [invoke]; the
    worker rechecks the observed holder atomically before effects. A failed
    snapshot is never an empty controller. Lifecycle callers may use
    [release_controller] under an already held credential transaction. *)
type mediation =
  release_controller:(holder:string -> reason:Machine_controller_contract.holder_departure ->
    (Mcp_protocol.Mcp_types.tool_result, invocation_error) result) ->
  snapshot:(unit -> (string option, string) result) ->
  invoke:(Machine_controller_contract.admission option -> (Mcp_protocol.Mcp_types.tool_result, invocation_error) result) ->
  (Mcp_protocol.Mcp_types.tool_result, invocation_error) result
