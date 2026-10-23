(** Gecko backend owned by the browser Add-on process. Its files are under the
    host's original per-incarnation private allocation, and its browser runs on
    a profile masc made in [profiles], never an operator profile. *)
type configuration = { driver : string; binary : string option; profiles : string }
(** [driver] and [binary] come from [[browser.automation]]. [profiles] is this
    instance's Gecko profile directory, made by the host with
    {!Browser_gecko_profile.prepare_instance}. *)
val configuration_to_json : configuration -> Yojson.Safe.t
val configuration_of_json : Yojson.Safe.t -> (configuration, string) result
val run : env:Eio_unix.Stdenv.base -> owner:Browser_addon_owner.t ->
  directory:string -> (unit -> unit) -> unit
(** Read the host-written automation.json, start the owned driver and publish it
    only after readiness. Each session runs on a fresh profile in [profiles],
    which is removed when the session ends and its browser has let it go.
    On exit retire admission, close the session and reap the driver. The
    settled result tells the owner whether the session closed cleanly; the host
    confirms cleanup from the worker's process group and the profile locks,
    never from a file this backend writes. Download bytes stay in this
    allocation until a host broker handles them; this backend never publishes
    ambient workspace artifacts. *)
