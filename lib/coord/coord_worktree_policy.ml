(** Coord Worktree - Policy parsing and clone-origin validation.

    Pure / read-only module: TOML-ish policy parsing for
    [tool_policy.toml]'s [git_clone] section, GitHub URL extraction, and
    [validate_clone_origin_url] gating used before auto-provisioning a
    sandbox clone.

    Extracted from [coord_worktree.ml] (Stage 06, godfile decomposition
    plan 2026-05-18). *)

let policy_string_array_of_line ~key line =
  let trimmed = String.trim line in
  let prefix = key ^ " =" in
  if not (String.starts_with ~prefix trimmed) then
    None
  else
    let raw =
      String.sub trimmed (String.length prefix)
        (String.length trimmed - String.length prefix)
      |> String.trim
    in
    if String.length raw < 2 || raw.[0] <> '[' || raw.[String.length raw - 1] <> ']'
    then
      Some []
    else
      let body = String.sub raw 1 (String.length raw - 2) in
      let items =
        body
        |> String.split_on_char ','
        |> List.map String.trim
        |> List.filter (fun s -> s <> "")
        |> List.filter_map (fun token ->
             let len = String.length token in
             if len >= 2 && token.[0] = '"' && token.[len - 1] = '"' then
               Some (String.sub token 1 (len - 2) |> String.lowercase_ascii)
             else
               None)
      in
      Some items

let git_clone_policy_paths ~base_path =
  let canonical =
    Filename.concat
      (Common.masc_dir_from_base_path ~base_path |> fun d -> Filename.concat d "config")
      "tool_policy.toml"
  in
  let legacy = Filename.concat (Filename.concat base_path "config") "tool_policy.toml" in
  canonical, legacy

let parse_git_clone_policy_content content =
  let rec loop in_git_clone allowed denied = function
    | [] -> allowed, denied
    | raw_line :: rest ->
        let line = String.trim raw_line in
        if line = "" || String.starts_with ~prefix:"#" line then
          loop in_git_clone allowed denied rest
        else if String.length line >= 2 && line.[0] = '[' && line.[String.length line - 1] = ']'
        then
          loop (String.equal line "[git_clone]") allowed denied rest
        else if not in_git_clone then
          loop in_git_clone allowed denied rest
        else
          let allowed =
            match policy_string_array_of_line ~key:"allowed_orgs" line with
            | Some items -> items
            | None -> allowed
          in
          let denied =
            match policy_string_array_of_line ~key:"denied_repos" line with
            | Some items -> items
            | None -> denied
          in
          loop in_git_clone allowed denied rest
  in
  loop false [] [] (String.split_on_char '\n' content)

let load_git_clone_policy_result ~base_path =
  let canonical, legacy = git_clone_policy_paths ~base_path in
  let read_or_empty p =
    match Safe_ops.read_file_safe p with
    | Error _ -> None
    | Ok content -> Some content
  in
  let content_opt =
    match read_or_empty canonical with
    | Some c -> Some c
    | None -> read_or_empty legacy
  in
  match content_opt with
  | None ->
      Error
        (Printf.sprintf
           "tool policy config not found at %s or %s"
           canonical legacy)
  | Some content -> Ok (parse_git_clone_policy_content content)

(* SSOT path resolution: canonical config root is [<base_path>/.masc/config/]
   (same primitive Config_dir_resolver.path_from_local_masc uses via
   Common.masc_dir_from_base_path). The legacy [<base_path>/config/] form is
   retained as a secondary lookup for older deployments. Reading order:
   canonical first, legacy fallback only when canonical is absent. *)
let load_git_clone_policy ~base_path =
  match load_git_clone_policy_result ~base_path with
  | Ok policy -> policy
  | Error msg ->
      Log.Coord.routine "git_clone_policy: using defaults (%s)" msg;
      [], []

let valid_github_org_slug org =
  let valid_org_char c =
    (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c = '-'
  in
  org <> "" && Seq.for_all valid_org_char (String.to_seq org)

let extract_github_org_repo url =
  let lc = String.lowercase_ascii (String.trim url) in
  let prefixes =
    [
      "https://github.com/";
      "git@github.com:";
      "ssh://git@github.com/";
    ]
  in
  let after_prefix =
    List.find_map
      (fun prefix ->
         if String.starts_with ~prefix lc then
           Some
             (String.sub lc (String.length prefix)
                (String.length lc - String.length prefix))
         else None)
      prefixes
  in
  match after_prefix with
  | None -> None
  | Some rest ->
      let rest =
        if String.ends_with ~suffix:"/" rest then
          String.sub rest 0 (String.length rest - 1)
        else rest
      in
      let stripped =
        if String.ends_with ~suffix:".git" rest then
          String.sub rest 0 (String.length rest - 4)
        else rest
      in
      match String.split_on_char '/' stripped with
      | [ org; repo ] when valid_github_org_slug org && repo <> "" ->
          Some (org ^ "/" ^ repo)
      | _ -> None

let extract_github_org url =
  match extract_github_org_repo url with
  | Some org_repo -> (
      match String.split_on_char '/' org_repo with
      | org :: _ -> Some org
      | [] -> None)
  | None -> None

let normalize_github_clone_url url =
  match extract_github_org_repo url with
  | Some org_repo -> "https://github.com/" ^ org_repo ^ ".git"
  | None -> url

let local_clone_origin_path url =
  let trimmed = String.trim url in
  let file_prefix = "file://" in
  let path =
    if String.starts_with ~prefix:file_prefix trimmed then
      Some
        (String.sub trimmed (String.length file_prefix)
           (String.length trimmed - String.length file_prefix))
    else if trimmed <> "" && not (Filename.is_relative trimmed) then
      Some trimmed
    else
      None
  in
  match path with
  | Some p when p <> "" -> Some p
  | _ -> None

let realpath_opt path =
  try Some (Unix.realpath path) with
  | Unix.Unix_error _ | Sys_error _ -> None

let path_is_under ~root path =
  match realpath_opt root, realpath_opt path with
  | Some root_real, Some path_real ->
      let root_prefix =
        if String.ends_with ~suffix:"/" root_real then root_real
        else root_real ^ "/"
      in
      String.equal root_real path_real
      || String.starts_with ~prefix:root_prefix path_real
  | _ -> false

let validate_local_clone_origin ~base_path url =
  match local_clone_origin_path url with
  | None -> None
  | Some path ->
      Some
        (if path_is_under ~root:base_path path then
           Ok ()
         else
           Error
             (Printf.sprintf
                "Local clone origin is outside base_path: origin=%s base_path=%s"
                path base_path))

let validate_clone_origin_url ~base_path url =
  match load_git_clone_policy_result ~base_path with
  | Error msg ->
      Error (Printf.sprintf "Git clone policy unavailable: %s" msg)
  | Ok (allowed_orgs, denied_repos) ->
      let allowed_lc = List.map String.lowercase_ascii allowed_orgs in
      let denied_lc = List.map String.lowercase_ascii denied_repos in
      match validate_local_clone_origin ~base_path url with
      | Some result -> result
      | None -> match extract_github_org_repo url with
      | None ->
          Error (Printf.sprintf "Cannot parse GitHub org/repo from URL: %s" url)
      | Some org_repo ->
          if List.mem org_repo denied_lc then
            Error (Printf.sprintf "Repository '%s' is in the denied list" org_repo)
          else
            match String.split_on_char '/' org_repo with
            | _org :: _ when allowed_lc = [] ->
                (* Explicit empty allowed_orgs means "any supported GitHub org",
                   still bounded by URL parsing and denied_repos. *)
                Ok ()
            | org :: _ when List.mem org allowed_lc -> Ok ()
            | org :: _ ->
                Error
                  (Printf.sprintf
                     "GitHub org '%s' not in allowed list: %s. Use the actual GitHub owner from the clone URL; do not infer an org from local workspace path segments."
                     org (String.concat ", " allowed_orgs))
            | [] ->
                Error (Printf.sprintf "Cannot parse GitHub org/repo from URL: %s" url)
