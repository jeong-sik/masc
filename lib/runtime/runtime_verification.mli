(** A selected-runtime readiness measurement, with no domain tools or failover.
    The only host-declared tool returns an unpredictable in-memory challenge. A model
    reply is not verified unless it consumed that actual tool result. *)
type unavailable =
  | Missing_credential
  | Unsupported_runtime
  | Tools_not_declared
  | Invalid_configuration
  | Client_unavailable

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

val verify
  :  sw:Eio.Switch.t
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
