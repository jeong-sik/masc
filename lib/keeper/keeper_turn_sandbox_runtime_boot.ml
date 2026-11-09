open Keeper_types_profile
open Keeper_turn_sandbox_runtime_work_root

(* Backends without authoritative complete boot facts use a process-owned
   boot record alongside their process-owned credential capability. Apple
   instead compares actual inspect facts and its durable guest snapshot. *)
type microvm_boot =
  { policy_port : int option
  ; image : string
  ; guest_size : Keeper_microvm_guest_size.t
  }

let microvm_boots : (string * microvm_boot) list Atomic.t = Atomic.make []

let microvm_boot container_name =
  Atomic.get microvm_boots |> List.assoc_opt container_name
;;

let rec record_microvm_boot container_name boot =
  let current = Atomic.get microvm_boots in
  let updated = (container_name, boot) :: List.remove_assoc container_name current in
  if not (Atomic.compare_and_set microvm_boots current updated)
  then record_microvm_boot container_name boot
;;

let rec forget_microvm_boot container_name =
  let current = Atomic.get microvm_boots in
  let updated = List.remove_assoc container_name current in
  if not (Atomic.compare_and_set microvm_boots current updated)
  then forget_microvm_boot container_name
;;

let forget_microvm_guest_state ~backend ~container_name =
  forget_microvm_work_root ~backend ~container_name;
  (match backend with
   | Keeper_microvm_backend.Apple_container -> ()
   | Keeper_microvm_backend.Nerdctl_kata | Keeper_microvm_backend.Microsandbox ->
     forget_microvm_boot container_name);
  Keeper_microvm_shim_readiness.forget ~backend ~guest_name:container_name
;;

(* Whether an adoptable policy guest still points at a live listener.

   Only [Network_policy] guests carry a proxy address, so every other mode
   answers true: there is no route to go stale. *)
let policy_route_holds ~network_mode ~booted_port ~bound_port =
  match (network_mode : Keeper_types_profile_sandbox.network_mode) with
  | Network_none | Network_inherit -> true
  | Network_policy ->
    (match booted_port, bound_port with
     | Some booted, Some bound -> booted = bound
     (* No record means this process did not boot it, and no bound port means
        there is nothing to point at. Neither is adoptable. *)
     | None, _ | _, None -> false)
;;

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

(* A running guest whose identity snapshot this process holds may be adopted
   when it was booted with what the keeper asks for now. Every difference is
   named, not only the first, so the log line that replaces a guest says all
   of what changed. *)
let microvm_adoption
      ~booted
      ~image
      ~(guest_size : Keeper_microvm_guest_size.t)
      ~network_mode
      ~bound_port
  =
  match booted with
  | None -> Replace_running_guest [ Boot_not_recorded ]
  | Some (booted : microvm_boot) ->
    let differs changed reason = if changed then Some reason else None in
    let booted_size = booted.guest_size in
    let reasons =
      List.filter_map
        Fun.id
        [ differs
            (not (String.equal booted.image image))
            (Image_changed { booted = booted.image; target = image })
        ; differs
            (not
               (Int.equal
                  (Keeper_microvm_guest_size.memory_mib booted_size.memory)
                  (Keeper_microvm_guest_size.memory_mib guest_size.memory)))
            (Memory_changed { booted = booted_size.memory; target = guest_size.memory })
        ; differs
            (not
               (Int.equal
                  (Keeper_microvm_guest_size.cpus_count booted_size.cpus)
                  (Keeper_microvm_guest_size.cpus_count guest_size.cpus)))
            (Cpus_changed { booted = booted_size.cpus; target = guest_size.cpus })
        ; differs
            (not
               (policy_route_holds
                  ~network_mode
                  ~booted_port:booted.policy_port
                  ~bound_port))
            (Policy_route_stale { booted_port = booted.policy_port; bound_port })
        ]
    in
    (match reasons with
     | [] -> Adopt_running_guest
     | _ :: _ -> Replace_running_guest reasons)
;;

let microvm_replacement_reason_to_string reason =
  let port = Option.fold ~none:"none" ~some:string_of_int in
  match reason with
  | Boot_not_recorded -> "this process has no record of booting it"
  | Image_changed { booted; target } -> Printf.sprintf "image %s -> %s" booted target
  | Memory_changed { booted; target } ->
    Printf.sprintf
      "memory %s -> %s"
      (Keeper_microvm_guest_size.memory_argv booted)
      (Keeper_microvm_guest_size.memory_argv target)
  | Cpus_changed { booted; target } ->
    Printf.sprintf
      "cpus %d -> %d"
      (Keeper_microvm_guest_size.cpus_count booted)
      (Keeper_microvm_guest_size.cpus_count target)
  | Policy_route_stale { booted_port; bound_port } ->
    Printf.sprintf "policy proxy port %s -> %s" (port booted_port) (port bound_port)
;;

(* The nameserver a guest is booted with: the one the workspace named, else the
   host's. Only the default network hands one, on a backend that spells
   [--dns]. [Network_none] has nothing to resolve on, [Network_policy] boots
   with [--no-dns] so the egress proxy is the only resolver, and Microsandbox
   spells its own [--dns-nameserver] and refuses the default network in
   [network_args_for]: asking there would refuse boots that never use one, or
   put an unrelated refusal in front of msb's own.

   The start reads it once it has decided to boot, and before anything is
   stopped or deleted for that boot. A refusal after the running guest was
   deleted and its work volume trimmed would cost the keeper a guest for
   nothing. A start that adopts never reads it, so a host that joins another
   network does not refuse a guest that resolves. *)
let microvm_boot_nameserver ~backend ~network_mode =
  match (network_mode : Keeper_types_profile_sandbox.network_mode) with
  | Keeper_types_profile_sandbox.Network_none
  | Keeper_types_profile_sandbox.Network_policy -> Ok None
  | Keeper_types_profile_sandbox.Network_inherit ->
    (match (backend : Keeper_microvm_backend.t) with
     | Keeper_microvm_backend.Microsandbox -> Ok None
     | Keeper_microvm_backend.Apple_container | Keeper_microvm_backend.Nerdctl_kata ->
       Result.map Option.some (Env_config_sandbox.Runtime.microvm_dns ()))
;;
