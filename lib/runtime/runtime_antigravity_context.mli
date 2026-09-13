(** Observe the selected model's official status-line payload in a disposable
    authenticated HOME, without sending a prompt or granting tool access. *)
(** The subprocess step an observation stopped in. *)
type phase =
  | Observation_deadline of float
      (** [timeout_s] was not a positive finite number; nothing ran. *)
  | Executable_lookup of string
      (** The interpreter or CLI command, as given, resolved to no regular
          executable file; nothing ran. *)
  | Version_probe  (** The shim exec of [cli --version]. *)
  | Status_transport  (** The PTY transport run itself. *)
  | Transport_reported of transport_outcome
      (** The transport exited 0 and wrote one of its failure statuses. *)

(* The failure statuses the embedded transport script can write. *)
and transport_outcome =
  | Transport_failed  (** The CLI exited without producing a status line. *)
  | Transport_interrupted  (** The transport received SIGTERM or SIGINT. *)

type error =
  | Private_home_unavailable
  | Command_failed of
      { phase : phase
      ; status : Unix.process_status option
          (** [None] when no child process existed for that phase: the
              deadline and lookup phases, or a spawn refusal. *)
      ; stderr_tail : string
          (** The last bytes of the child's stderr, trimmed; for a spawn
              refusal, the refusal text ({!Process_eio.spawn_refusal_to_string}),
              carried so the receipt says why nothing ran. *)
      }
  | Timed_out
  | Invalid_observation

val error_message : error -> string

(** [python_path] is the caller-resolved packaged interpreter. Each subprocess
    phase uses [timeout_s]; PTY teardown completes before private HOME removal.
    Eio cancellation is deferred across that bounded PTY phase to avoid leaving
    its separately-owned terminal process group alive. *)
val observe
  :  python_path:string
  -> cli_path:string
  -> timeout_s:float
  -> oauth_source:string
  -> model:Runtime_antigravity_setup.model
  -> (Runtime_antigravity_setup.context_observation, error) result

module For_testing : sig
  (** Interpret one transport run as [(status, stdout, stderr)]. *)
  val parse_transport
    :  model:Runtime_antigravity_setup.model
    -> cli_version:string
    -> Unix.process_status * string * string
    -> (Runtime_antigravity_setup.context_observation, error) result
end
