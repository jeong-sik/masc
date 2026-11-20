(** Background server startup, readiness observation, and contact-triggered
    credential/settings reconciliation with explicit session state [t]. *)

type t

val create : unit -> t

val spend_auto_start : t -> unit
(** Mark the per-session auto-start budget as consumed. *)

val set_credential_retry_pending : t -> bool -> unit

val launch_credential_preparation
  :  Masc_tui_types.state
  -> purpose:Masc_tui_credential_preparation.purpose
  -> base_path:string
  -> host:string
  -> port:int
  -> unit

val start_here_then_read
  :  t
  -> Masc_tui_types.state
  -> base_path:string
  -> host:string
  -> port:int
  -> unit

val apply_settled_starts
  :  t
  -> Masc_tui_types.state
  -> on_server_ready:(host:string -> port:int -> unit)
  -> bool

val react_to_contact
  :  t
  -> Masc_tui_types.state
  -> base_path:string
  -> host:string
  -> port:int
  -> unit
