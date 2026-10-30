(** Docker lifecycle for one owned job. Durable launch/start intent and private
    workspace/CLI-directory ownership are established by the caller. *)

type spec =
  { job_id : string
  ; keeper_name : string
  ; base_path : string  (** Existing physical root from [canonical_base_path]. *)
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
  | Log_capture_incomplete of { stream : Process_output_capture.stream; path : string; byte_length : int }
  | Log_capture_failed of { stream : Process_output_capture.stream; path : string option; detail : string }
  | Log_publication_failed of string

val error_to_string : error -> string

type base_path_error =
  | Invalid_base_path of string
  | Missing_base_path
  | Non_directory_base_path
  | Base_path_io_failed of string

val base_path_error_to_string : base_path_error -> string
val canonical_base_path : string -> (string, base_path_error) result
(** Normalize the explicit workspace input on the caller, then resolve its
    existing physical directory on a host thread. Parent-directory aliases
    identify the same workspace; a symbolic link at the root itself is refused.
    Missing/unreadable roots never fall back to lexical spelling. Cancellation
    propagates. This is name resolution, not frozen directory/effect authority. *)

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

type presence_hint =
  | No_owned_container_seen
  | Owned_container_seen
  | Presence_unavailable of error

type presence_round
val create_presence_round : unit -> presence_round
(** Empty, process-local read scope for one maintenance pulse. Single-domain
    Eio callers may share it across recovery fibers; it performs no I/O until
    an unchanged held owner asks for a hint. Never retain it across pulses. *)

val presence_hint : ?round:presence_round -> preparation -> presence_hint
(** Non-authoritative reactivation hint for a previously held absent job.
    Check the original private-directory/CLI authority and exact owner-label
    inventory, without observing daemon identity or accepting a container.
    Absence cannot settle a phase, authorize cleanup or permit another launch.
    A positive hint must go through full [inspect] before any state change or
    effect. With [round], equivalent frozen backend routes share one in-flight
    inventory through a fresh empty CLI directory, never another job's CLI.
    Shared rows come from complete owned pipe captures, never bounded process
    previews; incomplete capture cannot establish absence.
    Each caller validates its own directories before and after the shared read.
    Changed routes do not share; cancellation may restart this read-only fetch
    for a remaining caller. Errors remain explicit; cancellation propagates. *)

val create : preparation -> (observation, error) result
val start : container_id:string -> preparation -> (observation, error) result
val cancel : container_id:string -> preparation -> (observation, error) result
(** Exact saved container_id is required for start/cancel and is checked before
    the effect; a replacement with copied job labels cannot inherit it.
    One effectful CLI call, followed by canonical observation. No retry.
    Nonzero CLI exits are unconfirmed effects. Cancellation propagates; the
    caller's persisted intent remains authoritative when no receipt returns.
    Cancel kills only an exactly verified owned running container. A cancelled
    job whose exact label inventory confirms no owned container closes into a
    terminal cancelled phase instead of waiting forever. Terminal resources are cleaned only after durable result delivery, through
    the removal contract below; owner journals and output artifacts remain retained. *)

type logs = { stdout : Tool_output.artifact_ref; stderr : Tool_output.artifact_ref }
val logs : container_id:string -> preparation -> (logs, error) result
(** Capture both streams to private files outside the workspace and CLI config.
    Return durable artifact references only after both observed pipe EOF and
    complete-file publication. Bounded process previews never become complete
    logs. Completeness covers the delivered backend streams; Docker log
    retention determines what remains available. Saved container identity and private-directory authority are checked
    before and after capture. Cancellation propagates and partial capture files
    remain evidence. No limit, timeout or retry is added. *)

type removal_target =
  | Never_created
  | Absent_after_launch of string
  | Before_start of string
  | After_exit of { container_id : string; exit_code : int }
val remove_container : target:removal_target -> preparation -> (unit, error) result
(** Called only after durable terminal result/delivery and removal intent.
    Inspect the saved daemon/owner/isolation contract; remove only the exact
    saved Created/Stopped container without force. Running/replaced/unknown
    resources refuse, including a changed terminal phase or exit code. Absence
    is canonical recovery evidence, not CLI prose. [Never_created] authorizes
    absence confirmation only, never removal of a container.
    [Absent_after_launch] also confirms the exact saved container ID is absent;
    it never authorizes removal if that container reappears. *)
val remove_data : preparation -> (unit, error) result
(** Called only after confirmed container removal and durable data-removal
    intent. Delete the original private data tree (workspace, CLI and captures)
    through no-follow descriptors and frozen retained parents. An interrupted
    deletion may resume or confirm absence. Owner journals and blob roots stay. *)
