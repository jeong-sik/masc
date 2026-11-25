(** On-demand HTTP GET planner for the active workspace, sub-tab, dive, or
    overlay.

    Skips already-fresh [Observed.Value] slices unless [force = true], ensuring
    zero idle polling. *)

val fetches_for_current_view : ?force:bool -> Model.t -> Cmd.t list

val verification_requests_read : Work_store.t -> Cmd.get_request

val overlay_fetches : Model.t -> Cmd.t list
(** The open overlay's GETs that are not held fresh. An overlay opens over any
    workspace or dive, so a reply that leaves its slots stale asks for these
    wherever the overlay is. *)

val chat_status_fetches : keeper:string -> Model.t -> Cmd.t list
(** Detached nonterminal requests are reconciled by their own operation ids. *)

val cut_reply_fetches : keeper:string -> Model.t -> Cmd.t list
(** The journal pages [keeper]'s cut replies wait for, when that keeper's Chat
    transcript is on screen. The Chat tab's fetch list can only name the
    failure rows once the history has landed, so the history reply asks for
    these. *)

val hydrate_chat_tool_results :
  ?allow_next_page:bool ->
  ?keeper:string ->
  Model.t ->
  Model.t * Cmd.t list
(** Dispatch bounded on-demand [Get_keeper_tool_result] requests (up to the 6
    most recent visible uncached [execution_id]s) when the active keeper's
    Chat transcript is on screen and tools are expanded ([Tools_results] or
    [Tools_full]). Marks dispatched IDs in-flight in [Keeper_context_store] to
    prevent duplicate requests. *)

val selected_wiki_page_fetch : Model.t -> Cmd.t list
(** The selected Wiki page's GET when the Wiki tab is on screen and the page
    body is not held fresh. The Wiki tab's fetch list can only name a page
    once the index has landed, so the index reply asks for this. *)

val bootstrap_fetches : Model.t -> Cmd.t list
(** Initial/recovery fetch batch emitted after a healthy [/health] handshake. *)

val keeper_lifecycle_refresh_fetches : name:string -> Model.t -> Cmd.t list
(** Immediate post-mutation refresh after a Keeper lifecycle reply (success,
    HTTP 202 partial resume, or non-mismatch failure/error): always refreshes
    [Get_keepers_roster], plus the active Keeper tab when currently viewing
    [name] on [4 Keepers]. *)

val read_board_quarantines : now:Masc_tui_core.Clock.Mono.t -> keeper:string -> Model.t -> Model.t * Cmd.t list
