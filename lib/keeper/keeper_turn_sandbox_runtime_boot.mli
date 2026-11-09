(** What this process remembers about booting a guest and what it decides from
    that: the boot record per guest name, forgetting the state of a guest,
    whether the policy proxy port still holds, the reasons a running guest is
    replaced instead of adopted with their text, and the nameserver a boot is
    given.

    [Keeper_turn_sandbox_runtime] includes this module. *)

(* Backends without authoritative complete boot facts use a process-owned
   boot record alongside their process-owned credential capability. Apple
   instead compares actual inspect facts and its durable guest snapshot. *)
type microvm_boot =
  { policy_port : int option
  ; image : string
  ; guest_size : Keeper_microvm_guest_size.t
  }

val microvm_boot : string -> microvm_boot option

val record_microvm_boot : string -> microvm_boot -> unit

val forget_microvm_boot : string -> unit

val forget_microvm_guest_state :
  backend:Keeper_microvm_backend.t -> container_name:string -> unit

val policy_route_holds :
  network_mode:Keeper_types_profile_sandbox.network_mode ->
  booted_port:'a option -> bound_port:'a option -> bool

type microvm_replacement_reason =
  | Boot_not_recorded
  | Image_changed of
      { booted : string
      ; target : string
      }
  | Memory_changed of
      { booted : Keeper_microvm_guest_size.memory
      ; target : Keeper_microvm_guest_size.memory
      }
  | Cpus_changed of
      { booted : Keeper_microvm_guest_size.cpus
      ; target : Keeper_microvm_guest_size.cpus
      }
  | Policy_route_stale of
      { booted_port : int option
      ; bound_port : int option
      }

type microvm_adoption =
  | Adopt_running_guest
  | Replace_running_guest of microvm_replacement_reason list
      (** Never empty: every reason the guest may not be adopted. *)

val microvm_adoption :
  booted:microvm_boot option ->
  image:string ->
  guest_size:Keeper_microvm_guest_size.t ->
  network_mode:Keeper_types_profile_sandbox.network_mode ->
  bound_port:int option -> microvm_adoption

val microvm_replacement_reason_to_string :
  microvm_replacement_reason -> string

val microvm_boot_nameserver :
  backend:Keeper_microvm_backend.t ->
  network_mode:Keeper_types_profile_sandbox.network_mode ->
  (Ipaddr.t option, string) result
