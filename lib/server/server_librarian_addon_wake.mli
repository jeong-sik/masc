(** Thin hint bridge onto the existing serialized per-Keeper Memory lanes. *)
val install : sw:Eio.Switch.t -> config:Workspace.config -> unit
(** Subscribe once for the served workspace's Librarian Addon. Callbacks only
    schedule a child on this server switch; actual original-owner/epoch and
    queue discovery happens after yielding in that child. Result hints wake
    only their strictly restored original Keeper. Configuration/export hints
    rescan the actual pending queue names. No provider, commit, timer, retry
    policy, second owner or registry is introduced; shutdown fences copied
    callbacks and unsubscribes this exact registration. *)
