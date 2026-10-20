(** The Chrome backend belongs to the native browser Add-on, including its
    session switch and selected shared Exact Output callback. *)
type configuration
val configuration : browser:Browser_configuration.stagehand -> launcher:string ->
  guardian:string -> claim_directory:string -> (configuration, string) result
(** Pins host-selected executables and a stable, per-worker child claim outside
    the disposable allocation. Currently accepts fresh private profiles only;
    an operator profile is refused rather than reset or silently substituted. *)
val configuration_to_json : configuration -> Yojson.Safe.t
val configuration_of_json : Yojson.Safe.t -> (configuration, string) result
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
