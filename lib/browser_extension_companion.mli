(** Private extension execution on the original owned Browser transport.
    Programs are trusted installed companion code, never model arguments. *)
val create : sw:Eio.Switch.t -> backend:'session Browser_stagehand_backend.t ->
  transport:('session ->
    (Browser_cdp.t -> worker:Browser_cdp.session_id -> (Yojson.Safe.t, unit) result) ->
    (Yojson.Safe.t, unit) result) ->
  (Browser_extension_protocol.command -> (Yojson.Safe.t, Browser_extension_protocol.error) result)
(** Prepare pins the original session/tab, loads once on that transport and
    waits for its exact service worker without polling/deadline. Its setup
    program must return [{ready:true}] after enabling safe agentic behavior;
    the page slot stays held throughout. Invoke uses that exact worker and
    resolves Chrome's numeric tab id through the original Stagehand debugger
    target table. No URL matching, active-tab or replacement-worker fallback.
    Worker loss fences every original session pin before page work can resume.
    Requests/results are memory-only and never enter public tool retention. *)
