(** Structured workspace jobs and their original cancellation ownership. *)

type event = Cancellation_requested | Registration_released
val fork :
  ?observation:bool -> ?key:unit ref -> ?on_withdrawn:(unit -> unit) -> ?observe:(event -> unit) ->
  Masc_tui_types.state -> sw:Eio.Switch.t -> (unit -> unit) -> unit
(** Register before dispatch and unregister only after the actual worker body
    and its cleanup finish. A supplied physical [key] must be unique to this
    job; omitting it allocates a fresh key. Workspace withdrawal cancels all
    jobs; read withdrawal additionally selects observations. Cancellation is
    not a delivered successful result. Synchronous launch failure unregisters
    the key before re-raising to the launch boundary.
    [observe] is a synchronous diagnostic callback, not job authority. Cancellation
    is requested even if that callback raises; release is observed only after
    unregistering the original key, including synchronous launch failure. *)

val cancel_observation : Masc_tui_types.state -> key:unit ref -> unit
(** Request cancellation of this exact observation only. A missing key means
    there is no registered observation to cancel; it is not worker completion
    proof. The original registry entry remains until actual worker cleanup. *)
