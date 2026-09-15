(** The name every keeper sandbox container is created under.

    A container runtime refuses a name that breaks its rules, and it refuses
    at the boot, so a name built outside those rules is a keeper that cannot
    start -- on every turn, for the same reason. The only way to get a {!t}
    is {!make}, and {!make} only returns names the runtime the {!spec} is
    booted on accepts. *)

type t = private string

(** What the container is for, which fixes the runtime it reaches and the
    coordinates the name has to tell apart. *)
type spec =
  | Micro_vm_persistent of
      { keeper_name : string
      ; network_mode : Keeper_types_profile_sandbox.network_mode
      ; base_path : string
      }
      (** The keeper-lifetime guest. Stable: every process of the keeper
          computes the same name, so adopting a running guest is a probe. *)
  | Docker_persistent of
      { keeper_name : string
      ; network_mode : Keeper_types_profile_sandbox.network_mode
      ; base_path : string
      ; image : string
      }
      (** The keeper-lifetime Docker container. Stable like the guest, and
          also split by the resolved image reference. *)
  | Docker_oneshot of
      { keeper_name : string
      ; pid : int
      ; started_ms : int
      ; seq : int
      }
      (** A one-shot Docker container for one command. Unique per run. *)
  | Docker_read of
      { keeper_name : string
      ; pid : int
      ; started_ms : int
      }
      (** A one-shot Docker container for one read. Unique per run. *)

val make : spec -> t
(** Deterministic: the same [spec] always gives the same name.

    Docker bounds no name length, so a Docker spec is spelled in full. A
    microVM guest must fit every runtime the profile can select; the
    tightest is Apple's [container] at 63 characters. A guest name that
    fits is spelled in full; one that does not keeps its prefix, network
    mode and base-path hash, cuts the keeper segment, and ends in a digest
    of the full name, so two keepers that share the kept part of their names
    still get two guests. *)

val to_string : t -> string
