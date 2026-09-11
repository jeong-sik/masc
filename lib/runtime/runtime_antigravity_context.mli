(** Observe the selected model's official status-line payload in a disposable
    authenticated HOME, without sending a prompt or granting tool access. *)
type error =
  | Private_home_unavailable
  | Command_failed
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
  val parse_transport
    :  model:Runtime_antigravity_setup.model
    -> cli_version:string
    -> string
    -> (Runtime_antigravity_setup.context_observation, error) result
end
