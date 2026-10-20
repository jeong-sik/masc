(** The Chrome backend belongs to the native browser Add-on, including its
    session switch and selected shared Exact Output callback. *)
type configuration
val configuration : browser:Browser_configuration.stagehand -> launcher:string ->
  guardian:string -> claim_directory:string -> (configuration, string) result
(** Pins host-selected executables and a stable, per-worker child claim outside
    the disposable allocation. A configured profile is a dedicated persistent
    directory; its identity and stable shared resource slot are pinned without
    resetting its contents. External concurrent Chrome starts are unsupported. *)
val claim_directories : configuration -> string list
(** Every fresh child admission and launcher must claim these slots together.
    Recovery and old-owner termination continue to use the original child slot
    alone, even if a successor has acquired the shared persistent-profile slot. *)
val configuration_to_json : configuration -> Yojson.Safe.t
val configuration_of_json : Yojson.Safe.t -> (configuration, string) result
val verify_browser : admission:Native_addon_lease.t ->
  receipt:Browser_process_owner.ready -> Browser_cdp.t -> (unit, string) result
(** Before loading the extension or admitting page/model work, require the
    original kernel owner lease and child incarnation, query the connection's
    browser PID through SystemInfo.getProcessInfo, then recheck the owner and
    child. On refusal close only this CDP connection. Never signals a PID from
    a CDP reply or uses a matching command line as ownership. The caller still
    owns its original process manager and resource cleanup. *)
val settle : configuration -> incarnation:string -> directory:string -> (unit, string) result
(** Blocking recovery of this allocation's original child claim. Retire first,
    request termination by its kernel lease, and require Settled. A successful
    termination request alone does not establish cleanup. Never removes claims. *)
val cleanup : configuration -> incarnation:string -> directory:string -> (unit, string) result
(** Host only, after the original worker claim has settled and its allocation
    inode has been verified. Settle the child, then remove only its private
    profile trees without following links. Unknown resource types are retained. *)
val run : env:Eio_unix.Stdenv.base -> owner:Browser_addon_owner.t ->
  directory:string -> (unit -> unit) -> unit
(** Read the pinned stagehand.json and register the real session backend. Each
    session has a fresh child admission/profile and runs through the installed
    native launcher and browser process owner. Native input remains available
    without a model selection; model requests require the selected stagehand
    output and its request-schema grant. On retirement, revoke admission before
    releasing the backend switch and confirm the original child claim settled.

    Trusted native execution is not a sandbox; the guardian's foreground group
    contract does not include descendants that deliberately escape it. *)
