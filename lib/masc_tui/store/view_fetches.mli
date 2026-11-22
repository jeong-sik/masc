(** On-demand HTTP GET planner for the active workspace, sub-tab, dive, or
    overlay.

    Skips already-fresh [Observed.Value] slices unless [force = true], ensuring
    zero idle polling. *)

val fetches_for_current_view : ?force:bool -> Model.t -> Cmd.t list

val bootstrap_fetches : Model.t -> Cmd.t list
(** Initial/recovery fetch batch emitted after a healthy [/health] handshake. *)
