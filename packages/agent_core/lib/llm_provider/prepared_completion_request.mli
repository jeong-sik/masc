(** Private state machine for one canonical completion request.

    A measurement cannot be detached from one request and attached to another:
    [measured] owns the exact [t], and [admitted] owns that [measured] value.
    The public {!Complete} module exposes these states opaquely. *)

type t
type serialized
type measured
type admitted
type admitted_body

type context_fit =
  { input_tokens : int
  ; reserved_output_tokens : int
  ; max_context_tokens : int
  }

type fit_error =
  | Context_limit_unknown of { model_id : string }
  | Invalid_context_limit of
      { model_id : string
      ; max_context_tokens : int
      }
  | Output_reservation_unknown of { model_id : string }
  | Context_window_exceeded of context_fit
  | Serving_constraint_rejected of
      { constraint_ : Serving_constraint.t
      ; reason : Serving_constraint.admission_error
      }

val prepare
  :  config:Provider_config.t
  -> messages:Types.message list
  -> ?tools:Yojson.Safe.t list
  -> ?trace_context:(string * string) list
  -> ?capture_id:string
  -> ?stream_idle_timeout_s:float
  -> ?first_event_timeout_s:float
  -> ?body_timeout_s:float
  -> unit
  -> t

val request : t -> Llm_transport.completion_request

(** Serialize and admit the exact final completion body without network I/O.
    Streaming admission includes transport-owned stream-field injection. The
    returned immutable state owns the exact codec, body, and digest that an
    admitted built-in HTTP dispatch must consume. *)
val admit_serialized_body
  :  stream:bool
  -> t
  -> (serialized, Http_client.http_error) result

val measure
  :  ?connection_cache:Http_client.cache
  -> ?clock:_ Eio.Time.clock
  -> ?timeout_s:float
  -> sw:Eio.Switch.t
  -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> serialized
  -> (measured, Count_tokens_sync.completion_request_error) result

val attach_measurement
  :  t
  -> Exact_output_count_tokens.completion_request_measurement
  -> measured

(** Resolve the validated positive context-token limit from the explicit
    [max_context] config value, or the exact model capability when none was
    supplied. Pure: performs no measurement I/O. [Context_limit_unknown] when no
    limit is declared, [Invalid_context_limit] when it is non-positive. *)
val resolve_context_limit : t -> (int, fit_error) result

(** [true] when the exact resolved capability carries a serving constraint and
    therefore cannot use an unmeasured compatibility dispatch. *)
val requires_token_measurement : t -> bool

val serving_constraint : t -> Serving_constraint.t option

val admit
  :  now_unix_s:int
  -> max_context_tokens:int
  -> measured
  -> (admitted, fit_error) result

val admitted_request : admitted -> t
val admitted_fit : admitted -> context_fit
val admitted_body : admitted -> admitted_body option
val serialized_request : serialized -> t
val admitted_body_http_codec : admitted_body -> Provider_http_codec.t
val admitted_body_contents : admitted_body -> string
val admitted_body_evidence : admitted_body -> Request_wire_observer.observation
