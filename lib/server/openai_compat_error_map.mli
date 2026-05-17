(** Pure mapping from [Agent_sdk.Error.sdk_error] to the OpenAI-compat
    HTTP error envelope parts.

    Implements RFC-0105. The mapping is total: adding a new SDK error
    variant breaks the build at this site, forcing an explicit triage.

    No I/O, no logging — those remain at the caller. *)

(** HTTP status the OpenAI-compat surface should return for this error. *)
type http_status =
  [ `Bad_request           (** 400: validation, malformed input *)
  | `Unauthorized          (** 401: auth missing / invalid *)
  | `Not_found             (** 404: model / agent / task / resource not found *)
  | `Request_timeout       (** 408: client-cancelled *)
  | `Too_many_requests     (** 429: rate-limit / quota *)
  | `Internal_server_error (** 500: unclassified backend failure *)
  | `Bad_gateway           (** 502: upstream provider error *)
  | `Service_unavailable   (** 503: provider unavailable / cascade exhausted *)
  | `Gateway_timeout       (** 504: structural timeout *)
  ]

(** Structured mapping result. *)
type t = {
  http_status : http_status;
  openai_kind : string;          (** OpenAI envelope "type" field *)
  openai_code : string option;   (** OpenAI envelope "code" field (null when None) *)
  message     : string;          (** Human-readable, derived from sdk_error *)
}

(** Total map function. Exhaustive over [Agent_sdk.Error.sdk_error]. *)
val of_sdk_error : Agent_sdk.Error.sdk_error -> t
