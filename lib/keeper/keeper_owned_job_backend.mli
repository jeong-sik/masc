(** Docker lifecycle for one owned job. Durable launch/start intent and private
    workspace/CLI-directory ownership are established by the caller. *)

type spec =
  { job_id : string
  ; keeper_name : string
  ; base_path : string
  ; workspace_host_path : string
  ; argv : string list
  }

type preparation
(** Frozen daemon/context, image content identity, command, hardening and
    declared job-private writable footprint, including private directory
    device/inode and ownership. No container is created here. *)

val specification : preparation -> spec
(** Immutable owner, workspace and command recorded by this preparation. *)

type error =
  | Invalid_spec of string
  | Image_refused of Keeper_sandbox_image_resolver.error
  | Preparation_refused of string
  | Process_refused of { operation : string; refusal : Process_eio.spawn_refusal }
  | Command_failed of
      { operation : string
      ; status : Unix.process_status
      ; stdout : string
      ; stderr : string
      }
  | Response_rejected of { operation : string; detail : string }

val error_to_string : error -> string

val prepare :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  docker_config_path:string ->
  spec ->
  (preparation, error) result
(** Resolve the existing image and hardening authority. Inventory image-declared
    volumes and replace them with private tmpfs mounts, recorded before launch.
    The caller supplies an empty private CLI config directory outside the
    writable workspace. Host config, credentials and shared state are not
    mounted. A remote daemon cannot establish this local bind ownership. *)

val preparation_to_json : preparation -> Yojson.Safe.t
val preparation_of_json : Yojson.Safe.t -> (preparation, error) result
(** Strict closed preparation codec; decode performs no Docker effects. *)

type observation =
  | Absent
  | Created of string
  | Running of string
  | Stopped of string * int
  | Unconfirmed of string

val inspect : preparation -> observation
(** Exact label-filter inventory and inspect JSON verify the saved daemon,
    job/base/Keeper ownership, unchanged private directory identities, image,
    argv, mount and isolation contract.
    CLI prose never establishes absence, ownership or an effect outcome. *)

val create : preparation -> (observation, error) result
val start : container_id:string -> preparation -> (observation, error) result
val cancel : container_id:string -> preparation -> (observation, error) result
(** Exact saved container_id is required for start/cancel and is checked before
    the effect; a replacement with copied job labels cannot inherit it.
    One effectful CLI call, followed by canonical observation. No retry.
    Nonzero CLI exits are unconfirmed effects. Cancellation propagates; the
    caller's persisted intent remains authoritative when no receipt returns.
    Cancel kills only an exactly verified owned running container; stopped
    containers and their evidence remain available until explicit cleanup. *)

type logs = { stdout : string; stderr : string }
val logs : container_id:string -> preparation -> (logs, error) result
(** Captured streams from the exact verified container. Uses the existing
    process capture contract; it adds no limit, timeout or truncation policy. *)
