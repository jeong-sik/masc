(** On-demand HTTP GET planner for the active workspace, sub-tab, dive, or
    overlay.

    Skips already-fresh [Observed.Value] slices unless [force = true], ensuring
    zero idle polling. *)

val fetches_for_current_view : ?force:bool -> Model.t -> Cmd.t list

val overlay_fetches : Model.t -> Cmd.t list
(** The open overlay's GETs that are not held fresh. An overlay opens over any
    workspace or dive, so a reply that leaves its slots stale asks for these
    wherever the overlay is. *)

val selected_wiki_page_fetch : Model.t -> Cmd.t list
(** The selected Wiki page's GET when the Wiki tab is on screen and the page
    body is not held fresh. The Wiki tab's fetch list can only name a page
    once the index has landed, so the index reply asks for this. *)

val bootstrap_fetches : Model.t -> Cmd.t list
(** Initial/recovery fetch batch emitted after a healthy [/health] handshake. *)
