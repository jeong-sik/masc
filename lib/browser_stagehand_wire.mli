(** The JSON-RPC the Stagehand v4 extension speaks with its host, and the CDP
    expressions that carry it (RFC-browser-lane-stagehand §2, §3.3).

    The protocol's schema is [packages/protocol/stagehand.v4.json] in
    browserbase/stagehand. This module names only the part masc uses; wire
    keys are the schema's snake_case names. *)

(** The protocol major this client implements. The runtime reports its
    version in its readiness marker; another major is refused. *)
val supported_protocol_major : int

(** The CDP binding the extension calls with each message for the host. *)
val send_to_host_binding : string

(** A [Runtime.evaluate] expression that hands one encoded message to the
    extension. *)
val deliver_expression : string -> string

(** A [Runtime.evaluate] expression (with [awaitPromise]) that resolves to the
    runtime marker once the extension's receiver is installed. The CDP
    command deadline bounds the wait. *)
val readiness_expression : string

type marker = { protocol_version : string; runtime_version : string }

val marker_of_json : Yojson.Safe.t -> (marker, string) result

(** The leading number of [protocol_version]. *)
val protocol_major : marker -> (int, string) result

(** Chrome's id for an unpacked extension whose directory has this real path:
    the first 32 hex digits of its SHA-256, with [0]–[f] written [a]–[p]. *)
val extension_id_of_real_path : string -> string

type id = Int_id of int | String_id of string
type rpc_error = { code : int; message : string }

(** JSON-RPC codes masc answers with. *)
val method_not_found : int

val host_refused : int

type extension_request =
  | Llm_generate of { id : id; params : Yojson.Safe.t }
  | Unsupported_request of { id : id; method_ : string }

type extension_notification =
  | Log of Yojson.Safe.t
  | Page_event of Yojson.Safe.t
  | Unsupported_notification of { method_ : string }

type incoming =
  | Response of { id : id; result : (Yojson.Safe.t, rpc_error) result }
  | Request of extension_request
  | Notification of extension_notification

(** One message the extension sent through {!send_to_host_binding}. *)
val decode : string -> (incoming, string) result

type call =
  | Init of { protocol_version : string; client_version : string; browser_cdp_url : string }
  | Close
  | Act of { page_id : string; instruction : string }
  | Observe of { page_id : string; instruction : string option }
  | Extract of { page_id : string; instruction : string; schema : Yojson.Safe.t option }
  | Context_pages
  | Context_active_page
  | Page_goto of { page_id : string; url : string }
  | Page_screenshot of { page_id : string }
  | Page_evaluate of { page_id : string; expression : string }

val method_name : call -> string
val call_params : call -> Yojson.Safe.t

(** [true] for the calls during which the extension asks the host for a
    model answer ([llm.generate]). *)
val uses_model : call -> bool

val encode_call : id:int -> call -> string
val encode_reply : id:id -> (Yojson.Safe.t, rpc_error) result -> string
