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
type extra_root_match = { root : string; path : string }

let extra_root_match ?workdir ~extra_roots path =
  match extra_roots with
  | [] -> None
  | _ :: _ ->
      let lexical = normalize_path ?base_dir:workdir path in
      (* The narrowest root that admits the path: a reader holds the opened
         file to this root, and a wider declared root would admit more than
         the declaration nearest the path. Roots that admit a path all lie on
         its ancestor chain, so the longest is the narrowest. *)
      List.fold_left
        (fun best root ->
          let root = normalize_path root in
          if not (is_within_dir ~dir:root lexical) then best
          else
            match best with
            | Some { root = held; _ } when String.length held >= String.length root -> best
            | Some _ | None -> Some { root; path = lexical })
        None extra_roots

let extra_root_path ?workdir ~extra_roots path =
  Option.map (fun m -> m.path) (extra_root_match ?workdir ~extra_roots path)

let is_within_extra_root ?workdir ~extra_roots path =
  Option.is_some (extra_root_path ?workdir ~extra_roots path)

(** Path allowlist. When workdir is set, restrict to workdir + /tmp only.
    When unset, allow /tmp, cwd subtree, and the documented sandbox workspace
    root from [Host_config.sandbox_workspace_root]. In both cases a path
    within one of [extra_roots] is also allowed. *)
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
