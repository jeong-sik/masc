(** Resolve '.' and '..' segments in a path without filesystem access.
    This prevents path traversal attacks like /tmp/../../etc/passwd. *)
let normalize_path ?base_dir path =
  let abs =
    if Filename.is_relative path then
      let base =
        match base_dir with
        | Some dir -> dir
        | None -> Config_dir_resolver.current_working_dir ()
      in
      Filename.concat base path
    else
      path
  in
  Masc_exec.Path_scope.lexical_normalize_abs abs

(** Resolve symlinks in the existing prefix of a path and then append the
    remaining missing path segments lexically. *)
let resolve_path ?base_dir path =
  let abs = normalize_path ?base_dir path in
  Fs_compat.realpath_lenient abs |> normalize_path

(** Check whether [path] is exactly [dir] or a descendant of [dir]. *)
let is_within_dir ~dir path =
  path = dir || String.starts_with ~prefix:(dir ^ "/") path

(** [Some p] when [path] lies within one of [extra_roots], [p] being its
    lexical normal form; [None] otherwise. The roots are endpoint-side paths
    (an ssh endpoint's [allowed_paths]) that may not exist on this host, so
    both sides are normalized lexically: resolving them with the host's
    [Unix.realpath] would judge another machine's filesystem by this one. *)
let extra_root_path ?workdir ~extra_roots path =
  match extra_roots with
  | [] -> None
  | _ :: _ ->
      let lexical = normalize_path ?base_dir:workdir path in
      if
        List.exists
          (fun root -> is_within_dir ~dir:(normalize_path root) lexical)
          extra_roots
      then Some lexical
      else None

let is_within_extra_root ?workdir ~extra_roots path =
  Option.is_some (extra_root_path ?workdir ~extra_roots path)

(** Path allowlist. When workdir is set, restrict to workdir + /tmp only.
    When unset, allow /tmp, cwd subtree, and the documented sandbox workspace
    root from [Host_config.sandbox_workspace_root]. In both cases a path
    within one of [extra_roots] is also allowed.

    RFC-0084 §1.5 host-config-cleanup-E — replaces the ad-hoc
    [home/me] literal join with the typed
    [Host_config.sandbox_workspace_root] field introduced by PR-12.
    Behaviour change: when [HOME] is unset, the previous code rejected
    the fallback subtree entirely; now [Host_config.host]
    surfaces a documented fallback ([/tmp/masc-fleet]) which is allowed.
    This aligns the Fleet worker with the same SSOT that other keeper
    sandbox surfaces will migrate to in later cleanup PRs. *)
let validate_path ?workdir ~extra_roots path =
  let resolved = resolve_path ?base_dir:workdir path in
  let within_default_boundary =
    match workdir with
    | Some wd ->
        let resolved_wd = resolve_path wd in
        is_within_dir ~dir:(resolve_path "/tmp") resolved
        || is_within_dir ~dir:resolved_wd resolved
    | None ->
        let cfg = Host_config.host () in
        let cwd = Config_dir_resolver.current_working_dir () in
        is_within_dir ~dir:(resolve_path "/tmp") resolved
        || is_within_dir ~dir:(resolve_path cwd) resolved
        || is_within_dir ~dir:(resolve_path cfg.sandbox_workspace_root) resolved
  in
  within_default_boundary || is_within_extra_root ?workdir ~extra_roots path
