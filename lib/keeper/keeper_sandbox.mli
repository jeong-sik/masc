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

(** {1 Backend helpers} *)

val backend_to_string : backend -> string

val backend_of_profile :
  Keeper_types_profile_sandbox.sandbox_profile -> backend

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
    other LLM-facing surfaces; surfacing a host-absolute workspace
    path to a Docker keeper makes the LLM emit host paths inside the
    container, which fails because those paths do not exist there. *)
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
    {!host_root_abs}.  Surfacing a host-absolute workspace path to a
    Docker keeper makes the LLM emit host paths inside the container,
    which fails because that path does not exist there (#10650). *)
val keeper_visible_root_abs : t -> string

(** {1 Dashboard / status output} *)

(** Key-value fields describing the sandbox shape (id, backend,
    profile, network mode, lifetime, root/mind/repos args, overlay
    pattern). Suitable for splicing into a JSON [Assoc]. *)
val context_status_fields :
  t -> (string * Yojson.Safe.t) list
