(** What each runtime is told about the network: the name of the policy
    network, the argv that creates, lists and inspects it, whether a listing
    holds it, the gateway read back from it, the proxy a guest is pointed at
    and the network flags of a boot.

    [Keeper_sandbox_microvm] includes this module. *)

val policy_network_name : keeper_name:string -> string

val boot_plan_network :
  keeper_name:string
  -> Keeper_types_profile_sandbox.network_mode
  -> Keeper_microvm_boot_plan.network

(* The proxy a policy guest is pointed at: the gateway it sees the host at,
   and the port that keeper's listener bound. Both are discovered at boot --
   the gateway from the network, the port from the listener -- so neither is
   a constant here. *)
type policy_proxy =
  { gateway : string
  ; port : int
  }

val apple_policy_environment : policy_proxy -> (string * string) list

val apple_network_args :
  dns:string option ->
  policy_proxy:policy_proxy option ->
  Keeper_microvm_boot_plan.network -> (string list, string) result

val network_args_for :
  Keeper_microvm_backend.t ->
  dns:string option ->
  keeper_name:string ->
  policy_proxy:policy_proxy option ->
  Keeper_types_profile_sandbox.network_mode ->
  (string list, string) result

val policy_network_create_argv_for :
  Keeper_microvm_backend.t -> keeper_name:string -> (string list, string) result

val policy_network_list_argv_for : Keeper_microvm_backend.t -> (string list, string) result

val policy_network_present : keeper_name:string -> listing:string -> (bool, string) result

val policy_network_inspect_argv_for :
  Keeper_microvm_backend.t -> keeper_name:string -> (string list, string) result

val policy_network_gateway : inspect:string -> (string, string) result
