(** Keeper sandbox contract.

    Keeper-facing tools expose exactly one logical sandbox.  Its host side
    lives under [.masc/playground/], and that path is an implementation
    detail of the backends. *)

type backend = Keeper_types_profile_sandbox.sandbox_profile =
  | Docker
  | Micro_vm
  | Remote_ssh

type t =
  { keeper_name : string
  ; sandbox_id : string
  ; backend : backend
  ; network_mode : Keeper_types_profile_sandbox.network_mode
  ; host_root_rel : string
  ; host_root_abs : string
  ; container_root : string option
  ; root_arg : string
  }

let strip_trailing_slashes = Env_config_core.strip_trailing_slashes

(* One type, one projection. Every filesystem path a keeper LLM is shown has
   to pass through [Path], so that the compiler rejects a host path at an
   LLM-facing sink instead of a doc comment asking callers not to write one.

   The convention alone was already tried: keeper_sandbox.mli has said "use
   this in LLM-facing surfaces" since #10650, and the same host->container
   mapping was still reimplemented five times with three different fallback
   behaviours. Two of those fallbacks emit a string the keeper acts on as if
   it were real — the host path itself, or a silent collapse to the sandbox
   root that drops the repo segment. *)
module Path = struct
  type host
  type container
  type visible

  (* [+] is required, not stylistic: the parameter is phantom, so without a
     variance annotation OCaml cannot deduce it from the representation. The
     tags are distinct abstract types in the .mli, so covariance creates no
     subtyping between them — [host t] still fails to unify with
     [visible t]. *)
  type +'space t = string

  type conversion_error =
    | Outside_sandbox_root of
        { path : string
        ; host_root : string
        }
    | Container_root_missing of { path : string }

  let of_host_abs raw : host t = Env_config_core.normalize_path_lexically raw
  let unsafe_to_string (p : _ t) = p
  let visible_to_string (p : visible t) = p

  let conversion_error_to_string = function
    | Outside_sandbox_root { path; host_root } ->
      Printf.sprintf
        "path_outside_sandbox_root: %s is not under %s"
        path
        host_root
    | Container_root_missing { path } ->
      Printf.sprintf
        "container_root_missing: no container root is configured, cannot \
         project %s"
        path
  ;;
end

(* Where the tree is decides every projection below: a shared mount has a
   guest spelling for each host path, a tree the endpoint owns has only the
   host bookkeeping bundle on this side, and the remote lane's path
   translation ([Keeper_remote_path]) owns the endpoint spelling. *)
let tree_location_of_backend = Keeper_types_profile_sandbox.tree_location_of_profile

let backend_of_config_agent ~(config : Workspace.config) ~(agent_name : string) =
  Keeper_sandbox_config.sandbox_profile_of_agent
    ~base_path:config.Workspace.base_path
    ~agent_name

let sandbox_id_of_name name =
  "keeper:" ^ Playground_paths.sanitize_keeper_name name

(* The playground root of each profile is spelled once, in
   [Keeper_sandbox_config] (#21837). *)
let host_root_rel_of_profile = Keeper_sandbox_config.host_root_rel_of_profile

let host_root_rel_of_config_agent ~config ~agent_name =
  Keeper_sandbox_config.host_root_rel_of_agent
    ~base_path:config.Workspace.base_path
    ~agent_name

let host_root_abs_of_config_agent ~config ~agent_name =
  Keeper_sandbox_config.host_root_abs_of_agent
    ~base_path:config.Workspace.base_path
    ~agent_name

let host_root_rel_of_meta ~(meta : Keeper_meta_contract.keeper_meta) =
  host_root_rel_of_profile meta.sandbox_profile meta.name

let host_root_abs_of_meta ~(config : Workspace.config)
    (meta : Keeper_meta_contract.keeper_meta) =
  Filename.concat config.base_path (host_root_rel_of_meta ~meta)

let container_root name =
  Keeper_sandbox_config.container_root_of_agent ~agent_name:name

let host_path_of_visible_path ~config ~agent_name raw_path =
  if Filename.is_relative raw_path
  then raw_path
  else
    match tree_location_of_backend (backend_of_config_agent ~config ~agent_name) with
    (* The only host-side namespace such a keeper has is its bookkeeping
       bundle, so identity is the truthful mapping; the endpoint spelling is
       [Keeper_remote_path]'s, applied by the remote lane on the way out and
       back. *)
    | Endpoint_owned -> raw_path
    (* The sandbox mounts the keeper's host root at a guest path, so a visible
       path maps back the same way whatever runs the guest. *)
    | Shared_mount ->
        let container_prefix = container_root agent_name in
        if String.equal raw_path container_prefix
        then host_root_abs_of_config_agent ~config ~agent_name
        else if String.starts_with ~prefix:(container_prefix ^ "/") raw_path
        then (
          let suffix =
            String.sub
              raw_path
              (String.length container_prefix + 1)
              (String.length raw_path - String.length container_prefix - 1)
          in
          Filename.concat
            (host_root_abs_of_config_agent ~config ~agent_name)
            suffix)
        else
          raw_path

let of_meta ~(config : Workspace.config) ~(meta : Keeper_meta_contract.keeper_meta) : t =
  let backend = meta.sandbox_profile in
  { keeper_name = meta.name
  ; sandbox_id = sandbox_id_of_name meta.name
  ; backend
  ; network_mode = meta.network_mode
  ; host_root_rel = host_root_rel_of_meta ~meta
  ; host_root_abs = host_root_abs_of_meta ~config meta
  ; container_root =
      (match tree_location_of_backend backend with
       | Shared_mount -> Some (container_root meta.name)
       | Endpoint_owned -> None)
  ; root_arg = "."
  }

let sandbox_root_rel_of_meta ~(meta : Keeper_meta_contract.keeper_meta) : string =
  host_root_rel_of_meta ~meta

let sandbox_roots_of_meta ~(meta : Keeper_meta_contract.keeper_meta) : string list =
  [ sandbox_root_rel_of_meta ~meta ]

let keeper_visible_root_abs (t : t) : string =
  match t.container_root with
  | Some container -> container
  | None -> t.host_root_abs

(* The host -> keeper-visible projection. Fail-closed: a path that cannot be
   projected yields [Error], never the host path and never a collapse to the
   sandbox root. Both of those were live fallbacks in the implementations
   this replaces, and both hand the keeper a plausible string it then acts on
   as if the directory existed.

   Projection is not containment. For a tree the endpoint owns, the visible
   spelling on this side is the host bookkeeping path, so the answer is the
   input — that this returns an out-of-sandbox path unchanged is correct here
   and is decided elsewhere, by Keeper_alerting_path. For a shared mount the
   two coordinate systems are disjoint, so an out-of-root path has no visible
   spelling at all and must be an error. *)
let visible_path_of_host (t : t) (p : Path.host Path.t)
  : (Path.visible Path.t, Path.conversion_error) result
  =
  let path = Path.unsafe_to_string p in
  match tree_location_of_backend t.backend with
  (* Identity: the only keeper-visible namespace that exists host-side for a
     tree the endpoint owns is the bookkeeping bundle. The remote lane's path
     translation owns the endpoint spelling. *)
  | Endpoint_owned -> Ok path
  | Shared_mount ->
    (match t.container_root with
     | None -> Error (Path.Container_root_missing { path })
     | Some container_root ->
       (* Compare in canonical (realpath) coordinates, not lexical ones:
          [config.base_path] and an incoming host cwd routinely spell the
          same location differently through symlinks (/tmp vs /private/tmp
          on macOS). A lexical-only comparison reports the equivalent path
          as [Outside_sandbox_root], which downstream turns into the
          root-collapse substitute this module exists to remove. The
          superseded factory converter canonicalized both operands the
          same way. *)
       let canonical raw = Fs_compat.realpath_lenient raw |> strip_trailing_slashes in
       let host_root = canonical t.host_root_abs in
       let candidate = canonical path in
       let container_root =
         Env_config_core.normalize_path_lexically container_root
         |> strip_trailing_slashes
       in
       if String.equal candidate host_root
       then Ok container_root
       else if String.starts_with ~prefix:(host_root ^ "/") candidate
       then (
         let suffix =
           String.sub
             candidate
             (String.length host_root + 1)
             (String.length candidate - String.length host_root - 1)
         in
         Ok (Filename.concat container_root suffix))
       else
         (* The error carries the path as submitted, not its canonical
            respelling: diagnostics should name what the caller said. *)
         Error (Path.Outside_sandbox_root { path; host_root }))
;;

(* Boundary parse for a path that arrived as an untyped string, typically a
   [cwd] argument decoded from a keeper's tool call. A keeper may legitimately
   send either coordinate system, because the echoes it has been shown carry
   both, so decide once here rather than letting each tool guess. A string
   already rooted at the visible root is accepted as-is; anything else is read
   as a host path and projected. *)
let visible_path_of_raw (t : t) (raw : string)
  : (Path.visible Path.t, Path.conversion_error) result
  =
  let normalized = Env_config_core.normalize_path_lexically raw in
  let visible_root =
    keeper_visible_root_abs t
    |> Env_config_core.normalize_path_lexically
    |> strip_trailing_slashes
  in
  if String.equal normalized visible_root
     || String.starts_with ~prefix:(visible_root ^ "/") normalized
  then Ok normalized
  else visible_path_of_host t (Path.of_host_abs raw)
;;

let storage_lifetime = "persistent_backend_task_overlay"

let context_status_fields (t : t) : (string * Yojson.Safe.t) list =
  [ "sandbox_id", `String t.sandbox_id
  ; "sandbox_backend", `String (Keeper_types_profile_sandbox.sandbox_profile_to_string t.backend)
  ; "sandbox_profile", `String (Keeper_types_profile_sandbox.sandbox_profile_to_string t.backend)
  ; "sandbox_network_mode", `String (Keeper_types_profile_sandbox.network_mode_to_string t.network_mode)
  ; "sandbox_lifetime", `String storage_lifetime
  ; "sandbox_root", `String t.root_arg
  ; "sandbox_paths", `Assoc [ "root", `String t.root_arg ]
  ]
