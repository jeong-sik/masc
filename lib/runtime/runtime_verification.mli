(** A selected-runtime readiness measurement, with no domain tools or failover.
    The only host-declared tool returns an unpredictable in-memory challenge. A model
    reply is not verified unless it consumed that actual tool result. *)
type unavailable =
  | Missing_credential
  | Unsupported_runtime
  | Tools_not_declared
  | Invalid_configuration of string
  | Client_not_authenticated of string
      (** The official client started and answered, and reported no usable
          sign-in. Carries the client's own account of what it looked for. *)
  | Client_not_started of string
      (** The official client binary could not be launched at all. *)

type failure =
  | Unavailable of unavailable
  | Provider_rejected
  | Timed_out
  | Tool_not_called
  | Tool_result_not_consumed
  | Empty_response
  | Model_unreported

type observation =
  { model : string
  ; text : string
  }

type result =
  { runtime_id : string
  ; selected_model : string
    (** Requested configured API identity; never inferred from a vendor alias. *)
  ; observed_model : string option
    (** Nonempty identity reported by the transport. Aliases are preserved,
        not claimed equivalent to the requested identity. *)
  ; response : bool
  ; tool_called : bool
  ; tool_roundtrip : bool
  ; failure : failure option
  }

val to_json : result -> Yojson.Safe.t
val exit_code : result -> int

val initial_runtime_id
  : default_runtime_id:string
  -> assignments:(string * string) list
  -> lanes:Runtime_lane.t list
  -> keeper_name:string
  -> string option
(** Select the first target of the assigned lane, preferring declared lanes over
    bare runtime IDs exactly as initial routing does. This does not try fallbacks
    or claim an empty lane has a usable target. Pass materialized lanes. *)

val verify
  :  ?secure_random:Eio.Flow.source_ty Eio.Resource.t
  -> sw:Eio.Switch.t
  -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> mgr:_ Eio.Process.mgr
  -> clock:_ Eio.Time.clock
  -> cwd:Eio.Fs.dir_ty Eio.Path.t
  -> cwd_path:string
  -> timeout_s:float
  -> Runtime.t
  -> result

module For_testing : sig
  val measure
    :  runtime_id:string
    -> selected_model:string
    -> challenge:string
    -> run:
         (Runtime_official_client_tool.dynamic_tool
          -> prompt:string
          -> (observation, failure) Stdlib.result)
    -> result
end
