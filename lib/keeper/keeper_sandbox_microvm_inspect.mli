(** Whether a keeper's guest is running: the kind of container a keeper's VM
    is, how each runtime's inspect answer is read, the facts of an Apple guest,
    and the inspect and logs argv.

    [Keeper_sandbox_microvm] includes this module. *)

val keeper_vm_container_kind : string

val running_of_nerdctl_state_json : string -> (bool, string) result

val apple_guest_facts : container_name:string -> string -> Keeper_microvm_boot_plan.reading

val running_of_inspect_json_for :
  Keeper_microvm_backend.t -> string -> (bool, string) result

val inspect_argv_for : Keeper_microvm_backend.t -> container_name:string -> string list

val logs_tail_argv_for :
  Keeper_microvm_backend.t -> tail:int -> container_id:string -> string list
