(** The sandbox runtime of one turn: the container state, the record [t] with
    its constructor and accessors, the GitHub identity snapshots bound to it,
    the name of the persistent container for an image, and the
    [For_testing] module that builds a minimal record.

    [Keeper_turn_sandbox_runtime] includes this module. *)

open Keeper_meta_contract
open Keeper_turn_sandbox_runtime_registry
open Keeper_turn_sandbox_runtime_boot
open Keeper_types_profile

type state =
  | Not_started
  | Running of { container_name : string }

type t =
  { config : Workspace.config
  ; meta : keeper_meta
  ; image : (string, Keeper_sandbox_image_resolver.error) result
      (** Resolved once for the turn that made this runtime, so every start in
          the turn uses the same build even if a promote lands meanwhile. *)
  ; raw_host_root : string
  ; host_root : string
  ; container_root : string
  ; uid : int
  ; gid : int
  ; network_mode : network_mode
  ; state : state Atomic.t
  ; github_identity_snapshots : github_identity_snapshots Atomic.t
  }

val get_state : t -> state

val set_state : t -> state -> unit

val update_github_identity_snapshots :
  t ->
  (github_identity_snapshots ->
   github_identity_snapshots) ->
  unit

val bind_github_identity_snapshot :
  t ->
  github_identity_snapshot -> unit

val forget_github_identity_snapshots : t -> unit

val github_identity_secret_files : t -> string list

val host_root : t -> string

val normalize_path : string -> string

val container_root_of_meta : keeper_meta -> string

val create :
  config:Workspace.config ->
  meta:keeper_meta ->
  image:(string, Keeper_sandbox_image_resolver.error) result ->
  ?network_mode:Keeper_types_profile_sandbox.network_mode ->
  unit ->
  t

val image_unresolved_message : Keeper_sandbox_image_resolver.error -> string

val image : t -> (string, Keeper_sandbox_image_resolver.error) result

val docker_container_name_for_image : t -> image:string -> string

module For_testing :
  sig
    val minimal_image : string
    val create_minimal :
      config:Workspace_utils_backend_setup.config ->
      meta:keeper_meta -> state:state -> t
    val get_state : t -> state
    val set_state : t -> state -> unit
    val keeper_docker_container_name : t -> string
    val policy_route_holds :
      network_mode:Keeper_types_profile_sandbox.network_mode ->
      booted_port:'a option -> bound_port:'a option -> bool
    val microvm_adoption :
      booted:microvm_boot option ->
      image:string ->
      guest_size:Keeper_microvm_guest_size.t ->
      network_mode:Keeper_types_profile_sandbox.network_mode ->
      bound_port:int option ->
      microvm_adoption
    val microvm_boot_nameserver :
      backend:Keeper_microvm_backend.t ->
      network_mode:Keeper_types_profile_sandbox.network_mode ->
      (Ipaddr.t option, string) result
  end
