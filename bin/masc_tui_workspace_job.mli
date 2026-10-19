(** Structured workspace jobs and their original cancellation ownership. *)

val fork :
  ?observation:bool -> ?key:unit ref -> ?on_withdrawn:(unit -> unit) ->
  Masc_tui_types.state -> sw:Eio.Switch.t -> (unit -> unit) -> unit
(** Register before dispatch and unregister only after the actual worker body
    and its cleanup finish. A supplied physical [key] must be unique to this
    job; omitting it allocates a fresh key. Workspace withdrawal cancels all
    jobs; read withdrawal additionally selects observations. Cancellation is
    not a delivered successful result. Synchronous launch failure unregisters
    the key before re-raising to the launch boundary. *)

val cancel_observation : Masc_tui_types.state -> key:unit ref -> unit
(** Request cancellation of this exact observation only. A missing key means
    there is no registered observation to cancel; it is not worker completion
    proof. The original registry entry remains until actual worker cleanup. *)
