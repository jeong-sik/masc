(** Firefox and its BiDi connection belong to one native browser Add-on.
    Filesystem operations in configuration/recovery are blocking. *)
type configuration
val configuration : browser:Browser_configuration.live_bidi -> launcher:string ->
  guardian:string -> claim_directory:string -> (configuration, string) result
(** Require an existing private profile; pin its canonical directory and stable
    shared native claim inodes. Never adopts a listening Firefox. *)
val configuration_to_json : configuration -> Yojson.Safe.t
val configuration_of_json : Yojson.Safe.t -> (configuration, string) result
val claim_directories : configuration -> string list
val check_retained_child : configuration -> incarnation:string -> directory:string -> (unit, string) result
(** Read the child claim {!settle} recovers, without its gate lock, fence or any
    write: the slot through [Native_addon_lease.inspect], and its cleanup
    descriptor compared with the one this allocation recomputes. A missing
    slot is [Ok]. *)
val settle : configuration -> incarnation:string -> directory:string -> (unit, string) result
val cleanup : configuration -> incarnation:string -> directory:string -> (unit, string) result
(** Recovery stops only this allocation's original child claim and requires its
    settlement. Persistent profile data and shared claim files are preserved. *)
val run : env:Eio_unix.Stdenv.base -> owner:Browser_addon_owner.t ->
  directory:string -> (unit -> unit) -> unit
(** Read live-bidi.json, start the original guardian/Firefox and verify its lease,
    birth/group, reported profile and BiDi process ID before registering one UUID.
    Poll/result traffic stays in process. Retired/lost clients are never replaced
    or replayed. Retirement closes the verified original browser once, joins its
    owner and checks the child claim; an abort retains an unconfirmed outcome.
    The caller's work starts only after that exact client is attached. A configured
    backend startup failure fails this worker's discovery; it does not silently
    substitute another lane. Unexpected backend loss revokes the owner and wakes
    the caller's work with an error after joining original resource cleanup. *)
module For_testing : sig
  val run : before_command_validation:(unit -> unit) -> env:Eio_unix.Stdenv.base ->
    owner:Browser_addon_owner.t -> directory:string -> (unit -> unit) -> unit
  (** Observe command validation entry before its original native-gate read.
      The hook changes neither the admitted command nor process authority. *)
end
