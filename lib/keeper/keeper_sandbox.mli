(** Keeper_sandbox — Keeper-facing sandbox contract.

    Keeper tools expose exactly one logical sandbox. The current
    local-storage implementation lives at
    [.masc/playground/<keeper>], but that path is an implementation
    detail of the local / docker backends. *)

(** {1 Types} *)

type backend =
  | Local
  | Docker

type t = {
  keeper_name : string;
  sandbox_id : string;
  backend : backend;
  sandbox_profile : string;
  network_mode : string;
  host_root_rel : string;
  host_root_abs : string;
  container_root : string option;
  root_arg : string;
  mind_arg : string;
  repos_arg : string;
  task_overlay_pattern : string;
}

type docker_mount_layout = {
  host_root_raw : string;
  host_root : string;
  container_root : string;
}

(** {1 Backend helpers} *)

val backend_to_string : backend -> string

(** {1 Path resolution} *)

(** [backend_of_config_agent ~config ~agent_name] resolves the keeper's
    declared backend from persisted keeper configuration. Callers that
    need sandbox shape should depend on this contract instead of reading
    keeper TOML or Docker path details directly. *)
val backend_of_config_agent :
  config:Workspace.config ->
  agent_name:string ->
  backend

(** [host_root_rel_of_config_agent ~config ~agent_name] returns the
    backend-scoped relative sandbox root for [agent_name]. *)
val host_root_rel_of_config_agent :
  config:Workspace.config ->
  agent_name:string ->
  string

(** [host_root_abs_of_config_agent ~config ~agent_name] returns the
    backend-scoped absolute host-side sandbox root for [agent_name]. *)
val host_root_abs_of_config_agent :
  config:Workspace.config ->
  agent_name:string ->
  string

(** [host_root_rel_of_profile sandbox_profile name] returns the
    backend-scoped relative sandbox root for the given profile/name. *)
val host_root_rel_of_profile :
  Keeper_types_profile_sandbox.sandbox_profile ->
  string ->
  string

(** [host_root_rel_of_meta ~meta] returns the backend-scoped relative
    sandbox root for [meta]. *)
val host_root_rel_of_meta :
  meta:Keeper_meta_contract.keeper_meta ->
  string

(** [host_root_abs_of_meta ~config meta] returns the absolute
    backend-scoped sandbox root for [meta]. *)
val host_root_abs_of_meta :
  config:Workspace.config ->
  Keeper_meta_contract.keeper_meta ->
  string

(** [container_root name] returns the in-container path used by the
    hardened Docker backend. *)
val container_root : string -> string

(** [docker_mount_layout_of_meta ~config meta] is the single source of
    truth for the Docker playground bind mount: host root, normalized host
    root, and container root. Docker run/exec argv, cwd rendering, and
    host-side validation should derive path translations from this value
    instead of recomputing the three roots independently. *)
val docker_mount_layout_of_meta :
  config:Workspace.config ->
  Keeper_meta_contract.keeper_meta ->
  docker_mount_layout

(** [container_path_of_host layout ~host_path] maps a host path under the
    mounted playground to its container-visible path. *)
val container_path_of_host :
  docker_mount_layout ->
  host_path:string ->
  (string, string) result

(** [container_cwd_of_host layout ~host_cwd] maps a host cwd into the
    mounted container namespace and falls back to [layout.container_root]
    when the cwd is outside the playground. *)
val container_cwd_of_host :
  docker_mount_layout ->
  host_cwd:string ->
  string

(** Rewrite host playground paths in arbitrary text to container paths,
    matching both raw and normalized host roots on path boundaries. *)
val rewrite_host_paths_to_container :
  docker_mount_layout ->
  string ->
  string

(** Rewrite container playground paths in arbitrary text to raw host paths
    on path boundaries. Used only for host-side validation and
    operator-facing result normalization. *)
val rewrite_container_paths_to_host :
  docker_mount_layout ->
  string ->
  string

(** [host_path_of_visible_path ~config ~agent_name raw_path] maps a
    sandbox-visible absolute path for [agent_name] back to the
    backend-scoped host path used for validation. Non-matching absolute
    paths and relative paths are returned unchanged. *)
val host_path_of_visible_path :
  config:Workspace.config ->
  agent_name:string ->
  string ->
  string

(** [keeper_visible_root_abs_of_meta ~config meta] is the absolute
    sandbox root the keeper LLM should treat as its working root,
    derived directly from [meta] without building the full record.
    For Docker keepers this is the in-container path
    ({!container_root}); for Local keepers this is the host path
    ({!host_root_abs_of_meta}). Use this in runtime_contract and
    other LLM-facing surfaces; surfacing the host path to a Docker
    keeper makes the LLM emit [cd /Users/.../.masc/playground/...]
    inside the container, which fails because that path does not
    exist there. *)
val keeper_visible_root_abs_of_meta :
  config:Workspace.config ->
  Keeper_meta_contract.keeper_meta ->
  string

(** {1 Construction} *)

(** [of_meta ~config ~meta] derives the full sandbox record from a
    keeper meta entry. Backend is chosen from [meta.sandbox_profile]. *)
val of_meta :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  t

(** {1 Access control hints} *)

(** Relative roots that tools may touch inside [meta]'s backend-scoped
    sandbox. Currently a single-element list. *)
val allowed_path_roots_of_meta :
  meta:Keeper_meta_contract.keeper_meta ->
  string list

(** Single backend-scoped relative root for [meta]. *)
val allowed_root_rel_of_meta :
  meta:Keeper_meta_contract.keeper_meta ->
  string

(** [keeper_visible_root_abs t] is the absolute path the keeper LLM
    should treat as its working root.  For Docker keepers this is the
    in-container path ({!container_root}); for Local keepers this is
    {!host_root_abs}.  Surfacing the host path to a Docker keeper makes
    the LLM emit [cd /Users/.../.masc/playground/...] inside the
    container, which fails because that path does not exist there
    (#10650). *)
val keeper_visible_root_abs : t -> string

(** {1 Dashboard / status output} *)

(** Key-value fields describing the sandbox shape (id, backend,
    profile, network mode, lifetime, root/mind/repos args, overlay
    pattern). Suitable for splicing into a JSON [Assoc]. *)
val context_status_fields :
  t -> (string * Yojson.Safe.t) list
