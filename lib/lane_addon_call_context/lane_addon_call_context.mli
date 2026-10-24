(** Host-to-worker control envelope. This travels on an unexported control tool,
    never in the model's arguments. It is trusted only on the host-owned stdio
    connection, not as an authentication scheme for a public worker endpoint. *)
type principal = Keeper of string | Authenticated_agent of string | Host_actor of string | Operator | Anonymous
(** [Host_actor] is identity admitted by a host HTTP authorization boundary,
    including explicitly allowed token-less local attribution. It conveys no
    Keeper-private installation access. *)
type companion = private { socket_path:string; invocation_id:string; max_message_bytes:int }
val companion_to_json : companion -> Yojson.Safe.t
val companion_of_json : Yojson.Safe.t -> (companion, string) result
(** Private invocation capability. Never retain or expose through model tools. *)
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
