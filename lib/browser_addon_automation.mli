(** Gecko backend owned by the browser Add-on process. All paths are under the
    host's original per-incarnation private allocation, never an operator profile. *)
val configuration_to_json : Browser_configuration.automation -> Yojson.Safe.t
val configuration_of_json : Yojson.Safe.t -> (Browser_configuration.automation, string) result
val run : env:Eio_unix.Stdenv.base -> owner:Browser_addon_owner.t ->
  directory:string -> (unit -> unit) -> unit
(** Read the host-written automation.json, start the owned driver and publish it
    only after readiness. On exit retire admission, close the session and reap
    the driver. Write automation-closed.json only after confirmed cleanup. Any
    uncertain session creation or lost session authority permanently prevents
    that receipt. Download bytes stay in this allocation until a host broker
    handles them; this backend never publishes ambient workspace artifacts. *)
module For_testing : sig
  val run : commit_receipt:(path:string -> contents:string -> (unit, string) result) ->
    env:Eio_unix.Stdenv.base -> owner:Browser_addon_owner.t -> directory:string ->
    (unit -> unit) -> unit
  (** Interpose on the actual final receipt commit to exercise cancellation at
      this I/O boundary. All startup, driver and cleanup code stays unchanged. *)
end
