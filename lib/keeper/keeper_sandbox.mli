(** Keeper_sandbox — Keeper-facing sandbox contract.

    Keeper tools expose exactly one logical sandbox. The current
    local-storage implementation lives at
    [.masc/playground/<keeper>], but that path is an implementation
    detail of the local / docker backends. *)

(** {1 Types} *)

type backend =
  | Docker
  | Micro_vm
  | Remote_ssh

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
}

(** {1 Keeper-visible paths} *)

(** Phantom-tagged filesystem paths, so that handing a keeper a path it
    cannot use is a type error rather than a review comment.

    Every path shown to a keeper LLM must be a [visible t], and the only
    way to obtain one is {!visible_path_of_host} or {!visible_path_of_raw}
    below. A [host t] does not unify with a [visible t], and [t] is fully
    abstract rather than [private string], so [(p :> string)] does not
    compile either — the sole erasure is {!Path.unsafe_to_string}, kept
    greppable on purpose.

    This exists because the convention was already tried and lost. This
    file has told callers to project before surfacing a path since #10650
    ("keeper_context_status sandbox_root leaks HOST absolute path",
    ~890 failed docker execs/day), and the mapping was nonetheless
    reimplemented five more times, three of them with a fallback that
    emits a path the keeper cannot use. *)
module Path : sig
  type host
  type container
  type visible

  type +'space t

  (** Reads an absolute host path, normalising it lexically. Total: any
      absolute string denotes some host location. Whether that location is
      one the keeper may touch is containment, decided by
      [Keeper_alerting_path], not here. *)
  val of_host_abs : string -> host t

  (** The sanctioned rendering for anything a keeper will read. *)
  val visible_to_string : visible t -> string

  (** Erasure that drops the guarantee. Every call site is a place the type
      stopped protecting the caller, so this stays deliberately awkward to
      name and easy to grep. *)
  val unsafe_to_string : _ t -> string

  type conversion_error =
    | Outside_sandbox_root of {
        path : string;
        host_root : string;
      }
    | Container_root_missing of { path : string }

  val conversion_error_to_string : conversion_error -> string
end

(** {1 Backend helpers} *)

val backend_to_string : backend -> string

val tree_location_of_backend : backend -> Keeper_types_profile_sandbox.tree_location
(** Where the backend's tree lives, which decides every projection below and
    every consumer's host-vs-remote branch: a Docker container mounts the
    host playground ([Shared_mount]); a microvm guest and an OpenSSH host
    own their tree ([Endpoint_owned]). *)

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
val sandbox_roots_of_meta :
  meta:Keeper_meta_contract.keeper_meta ->
  string list

(** Single backend-scoped relative root for [meta]. *)
val sandbox_root_rel_of_meta :
  meta:Keeper_meta_contract.keeper_meta ->
  string

(** [keeper_visible_root_abs t] is the absolute path the keeper LLM
    should treat as its working root.  For Docker keepers this is the
    in-container path ({!container_root}); for Local keepers this is
    {!host_root_abs}.  Surfacing a host-absolute workspace path to a
    Docker keeper makes the LLM emit host paths inside the container,
    which fails because that path does not exist there (#10650). *)
val keeper_visible_root_abs : t -> string

(** [visible_path_of_host t p] projects a host path into the coordinate
    system the keeper actually runs in. This is the single projection: the
    five earlier implementations differed only in what they did when the
    path did not map, and each of those answers — return the host path,
    collapse to the sandbox root, or search [repos/] for a plausible
    segment — produces a directory the keeper is then told exists.

    Local keepers share the host filesystem, so the projection is the
    identity and cannot fail. Docker keepers live in a disjoint tree, so a
    path outside the sandbox root has no visible spelling and is an
    [Error]; callers must say what to do about that rather than receive a
    substitute.

    Containment for Docker is decided in canonical (realpath) coordinates
    via {!Fs_compat.realpath_lenient}, so symlinked spellings of the same
    location ([/tmp] vs [/private/tmp] on macOS) project identically
    regardless of which spelling [config.base_path] or the input uses. *)
val visible_path_of_host :
  t ->
  Path.host Path.t ->
  (Path.visible Path.t, Path.conversion_error) result

(** [visible_path_of_raw t raw] parses a path that arrived as an untyped
    string — typically a [cwd] argument decoded from a keeper tool call.
    A keeper may send either coordinate system, since the payloads it has
    been shown historically carry both, so the ambiguity is resolved once
    here instead of in each tool. A string already rooted at the visible
    root is taken as visible; anything else is read as a host path and
    projected. *)
val visible_path_of_raw :
  t ->
  string ->
  (Path.visible Path.t, Path.conversion_error) result

(** {1 Dashboard / status output} *)

(** Key-value fields describing the sandbox shape (id, backend,
    profile, network mode, lifetime, root/repos args, overlay
    pattern). Suitable for splicing into a JSON [Assoc]. *)
val context_status_fields :
  t -> (string * Yojson.Safe.t) list
