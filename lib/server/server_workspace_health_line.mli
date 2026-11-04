(** The Home screen's Health line, taken from the mission briefing
    ([GET /api/v1/dashboard/briefing] with no actor): the workspace health
    word, whether the Keeper directory listed, and how many Keepers have a
    state no one can read (an unread Keeper, or a brief whose status word this
    build cannot name).

    The server recomputes the mission every 120 seconds
    ({!Server_dashboard_http_core.start_mission_refresh_loop}). Each
    recomputation is observed here, and a line that differs from the last one
    is announced as [workspace_health] (operator decision 2026-11-04: the
    health derives from many stores and from time passing, so it is
    recomputed on the server's clock and announced when it moves). *)

val of_briefing : Yojson.Safe.t -> Yojson.Safe.t
(** [{"workspace_health", "keepers_listing", "unreadable_keepers"}] of a
    briefing answer. A briefing without these fields gives an [Error]-shaped
    line ([{"error": ...}]), which the reader reports. *)

val observe : base_path:string -> Yojson.Safe.t -> unit
(** A mission recomputation finished with this briefing answer. Announces
    [workspace_health] when its line differs from the last one observed. *)
