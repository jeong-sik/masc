(** What this process has done to the persistent work volume of a guest: the
    table of work roots it has made with the state of their build links, the
    effects registered per backend and Keeper (an unverified cleanup, link
    application or maintenance makes the admissions refuse the next handoff),
    and the admissions, reservations and updates that read and change them.

    [Keeper_turn_sandbox_runtime] includes this module. *)

(* Guests whose keeper root on the work volume this server process has made.
   Names have a shortened workspace hash and are shared across backend stores,
   so readiness also carries the full normalized base and selected backend.
   The volume outlives the guest, so the [mkdir] is paid once per guest per
   process, at boot. A guest whose boot could not make the root and could
   not be taken down either is still running and still registered, so the
   next start adopts it: its readiness stays false, and the endpoint request
   makes the root before handing the guest out rather than handing out a
   guest every call fails in. *)
type microvm_work_root_key = string * Keeper_microvm_backend.t * string

type microvm_build_links_state =
  | Build_links_not_prepared
  | Build_links_effect_unverified
  | Build_links_prepared

type microvm_build_cleanup_state =
  | Build_cleanup_available
  | Build_cleanup_skipped_not_sent
  | Build_cleanup_effect_unverified
  | Build_cleanup_confirmed
  | Build_cleanup_finished_incomplete

val microvm_build_cleanup_outcome :
  Masc_exec.Sandbox_target.run_outcome ->
  Keeper_sandbox_remote.execution_observation option ->
  microvm_build_cleanup_state

(* Work/build volume names are Keeper-scoped, not workspace/guest-scoped.
   Group effects by that same nominal backend resource. This is not proof of
   a physical mount identity or authority over another server's guest. *)
type microvm_maintenance_attempt =
  { operation_id : string
  ; container_name : string
  ; observation : Keeper_sandbox_remote.execution_observation option
  }

type microvm_maintenance_state =
  | Maintenance_idle
  | Maintenance_unverified of microvm_maintenance_attempt

type microvm_work_effects =
  { resource : Keeper_microvm_backend.t * string
  ; cleanup_state : microvm_build_cleanup_state
  ; links_unverified : bool
  ; maintenance : microvm_maintenance_state
  }

val register_microvm_work_effects :
  backend:Keeper_microvm_backend.t ->
  keeper_name:string -> microvm_work_effects

val update_microvm_work_effects :
  backend:Keeper_microvm_backend.t ->
  keeper_name:string ->
  (microvm_work_effects -> microvm_work_effects option) -> bool

val set_microvm_build_cleanup_state :
  backend:Keeper_microvm_backend.t ->
  keeper_name:string ->
  expected:microvm_build_cleanup_state -> microvm_build_cleanup_state -> bool

val microvm_build_cleanup_unresolved_message : keeper_name:string -> string

val microvm_build_cleanup_admission :
  backend:Keeper_microvm_backend.t ->
  keeper_name:string -> (unit, string) result

val microvm_build_link_effect_admission :
  backend:Keeper_microvm_backend.t ->
  keeper_name:string -> (unit, string) result

val reserve_microvm_maintenance :
  backend:Keeper_microvm_backend.t ->
  keeper_name:string -> microvm_maintenance_attempt -> bool

val settle_microvm_maintenance :
  backend:Keeper_microvm_backend.t ->
  keeper_name:string ->
  operation_id:string ->
  observation:Keeper_sandbox_remote.execution_observation option ->
  resolved:bool -> bool

type microvm_work_root_ready =
  { key : microvm_work_root_key
  ; generation : unit ref
  ; root_ready : bool
  ; build_links_state : microvm_build_links_state
  }

val microvm_work_root_entry :
  base_path:string ->
  backend:Keeper_microvm_backend.t ->
  container_name:string -> microvm_work_root_ready option

val microvm_work_root_ready :
  base_path:string ->
  backend:Keeper_microvm_backend.t -> container_name:string -> bool

val register_microvm_work_root :
  base_path:string ->
  backend:Keeper_microvm_backend.t ->
  container_name:string -> microvm_work_root_ready

val complete_microvm_work_root :
  base_path:string ->
  backend:Keeper_microvm_backend.t ->
  container_name:string -> unit ref -> bool

val mark_microvm_work_root_ready :
  base_path:string ->
  backend:Keeper_microvm_backend.t -> container_name:string -> unit

val set_microvm_build_links_state :
  base_path:string ->
  backend:Keeper_microvm_backend.t ->
  container_name:string ->
  unit ref ->
  expected:microvm_build_links_state -> microvm_build_links_state -> bool

val microvm_build_links_admission :
  base_path:string ->
  backend:Keeper_microvm_backend.t ->
  keeper_name:string -> container_name:string -> (unit, string) result

val forget_microvm_work_root :
  backend:Keeper_microvm_backend.t -> container_name:string -> unit
