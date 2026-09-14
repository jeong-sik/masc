(** A selected-runtime readiness measurement, with no domain tools or failover.
    The only host-declared tool returns an unpredictable in-memory challenge. A model
    reply is not verified unless it consumed that actual tool result. *)
type unavailable =
  | Missing_credential of string
      (** The runtime requires an environment credential that is unset.
          Carries the dispatch check's own account, which names the variable. *)
  | Invalid_credential of string
      (** The runtime declares an inline or file credential that resolved to
          nothing usable. Carries the dispatch check's own account, which names
          the carrier, so a bad file is not reported as a missing one. *)
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
  | Provider_rejected of string
      (** The provider or client refused the verification request, carrying
          its own account of the refusal. Both a wire refusal and a request
          the provider never accepted arrive here, and the message alone sent
          operators to check credentials that were fine: twelve OpenRouter
          runtimes failed on one missing [reasoning-effort] key and reported
          provider_rejected with no detail (masc#35139). *)
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
val failure_code : failure -> string
val failure_message : failure -> string
val failure_detail : failure -> string option

type unmeasured =
  { runtime_id : string
  ; code : string
  ; message : string
  ; detail : string option
  }
(** What [unavailable_to_json] writes: the runtime was never measured, so there
    is no selected model and the code is the command's own, not a [failure]. *)

type report =
  | Measured of result
  | Unmeasured of unmeasured

val of_json : Yojson.Safe.t -> (report, string) Stdlib.result
(** Read back exactly what [to_json] or [unavailable_to_json] wrote. Refuses,
    naming the reason, a document with another schema, a missing or extra key,
    a failure code this module does not write, a detail that the code never
    carries (or a missing one it always carries), a status that disagrees with
    the failure, or a roundtrip that disagrees with it. [failure.message] is
    presentation derived from the code and is required to be a string but not
    compared, so wording can change without invalidating a report. *)
val unavailable_to_json
  :  ?detail:string
  -> runtime_id:string
  -> code:string
  -> message:string
  -> unit
  -> Yojson.Safe.t
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

(** [timeout_s] is one window over a runtime's whole readiness run, on
    [clock], for every arm: for an HTTP binding that is the wait for its
    admission permit, both provider round trips and the tool call between
    them; a run still inside it when the window closes is [Timed_out]. It
    is held by [measure] around each arm's [run], not declared per request,
    so nothing restarts it. *)
val verify
  :  secure_random:Eio.Flow.source_ty Eio.Resource.t
  -> sw:Eio.Switch.t
  -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> mgr:_ Eio.Process.mgr
  -> clock:_ Eio.Time.clock
  -> cwd:Eio.Fs.dir_ty Eio.Path.t
  -> cwd_path:string
  -> timeout_s:float
  -> Runtime.t
  -> result

(** {!verify} the way the [runtime-verify] command runs it: installs the
    process env and clock a provider request reads
    ({!Eio_context.set_env}, {!Eio_context.set_clock},
    {!Time_compat.set_clock}) and verifies with the env's network, entropy
    and file system, working in [private_dir]; children start through
    {!Posix_spawn_process_mgr.mgr}, the manager the server starts them with.
    The command and the suite that stands in for it both call this, so the
    suite runs the command's shape rather than a copy of it. *)
val verify_as_command
  :  env:Eio_unix.Stdenv.base
  -> sw:Eio.Switch.t
  -> private_dir:string
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
