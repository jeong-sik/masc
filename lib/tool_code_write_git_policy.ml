(** Git clone policy/cache/parser helpers extracted from [Tool_code_write]. *)

type policy_config_cache_entry =
  { base_path : string
  ; env_config_dir : string option
  ; result : (Keeper_tool_policy_config.t, string) Result.t
  }

let policy_config_cache : policy_config_cache_entry option ref = ref None

let reset_policy_config_cache () = policy_config_cache := None

let observe_policy_config_load_error ~base_path ~env_config_dir msg =
  let config_dir =
    Option.value ~default:"<resolved-from-base-path>" env_config_dir
  in
  Prometheus.inc_counter Keeper_metrics.metric_keeper_tool_policy_failures
    ~labels:
      [ ( "site"
        , Keeper_tool_policy_failure_site.(to_label Tool_code_write_load_failed) )
      ; "preset", "n/a"
      ]
    ();
  Log.Keeper.warn
    "tool_code_write: tool_policy.toml load failed; git clone policy is \
     unavailable (base_path=%S config_dir=%S): %s"
    base_path
    config_dir
    msg
;;

let get_policy_config_result ~base_path =
  (* RFC-0085 PR-8: route env-derived config_dir read through Host_config. *)
  let env_config_dir = (Host_config.from_env ()).config_dir in
  match !policy_config_cache with
  | Some { base_path = cached_base_path; env_config_dir = cached_env; result }
    when String.equal cached_base_path base_path
         && Option.equal String.equal cached_env env_config_dir -> result
  | _ ->
    let result = Keeper_tool_policy_config.load ~base_path in
    (match result with
     | Ok _ -> ()
     | Error msg -> observe_policy_config_load_error ~base_path ~env_config_dir msg);
    policy_config_cache := Some { base_path; env_config_dir; result };
    result
;;

let get_policy_config ~base_path =
  match get_policy_config_result ~base_path with
  | Ok cfg -> Some cfg
  | Error _ -> None
;;

let valid_github_org_slug org =
  let valid_org_char = function
    | 'a' .. 'z' | '0' .. '9' | '-' -> true
    | _ -> false
  in
  (not (String.equal org "")) && Seq.for_all valid_org_char (String.to_seq org)
;;

let github_clone_url_suffix url =
  let lc = String.lowercase_ascii (String.trim url) in
  let prefixes =
    [ "https://github.com/"; "git@github.com:"; "ssh://git@github.com/" ]
  in
  List.find_map
    (fun prefix ->
       if String.starts_with ~prefix lc
       then
         Some
           (String.sub lc (String.length prefix) (String.length lc - String.length prefix))
       else None)
    prefixes
;;

let extract_github_org url =
  match github_clone_url_suffix url with
  | None -> None
  | Some rest ->
    (match String.index_opt rest '/' with
     | None -> None
     | Some idx ->
       let org = String.sub rest 0 idx in
       if valid_github_org_slug org then Some org else None)
;;

let extract_github_org_repo url =
  match github_clone_url_suffix url with
  | None -> None
  | Some rest ->
    let rest =
      if String.ends_with ~suffix:"/" rest
      then String.sub rest 0 (String.length rest - 1)
      else rest
    in
    let stripped =
      if String.ends_with ~suffix:".git" rest
      then String.sub rest 0 (String.length rest - 4)
      else rest
    in
    (match String.split_on_char '/' stripped with
     | [ org; repo ] when valid_github_org_slug org && not (String.equal repo "") ->
       Some (org ^ "/" ^ repo)
     | _ -> None)
;;

let canonical_github_https_clone_url url =
  match extract_github_org_repo url with
  | Some slug -> Some ("https://github.com/" ^ slug ^ ".git")
  | None -> None
;;

let normalize_github_clone_url url =
  match canonical_github_https_clone_url url with
  | Some normalized -> normalized
  | None -> url
;;

let validate_clone_url ~base_path url =
  match get_policy_config_result ~base_path with
  | Error msg -> Error (Printf.sprintf "Git clone policy unavailable: %s" msg)
  | Ok cfg ->
    let allowed = Keeper_tool_policy_config.git_clone_allowed_orgs cfg in
    let denied = Keeper_tool_policy_config.git_clone_denied_repos cfg in
    let allowed_lc = List.map String.lowercase_ascii allowed in
    let denied_lc = List.map String.lowercase_ascii denied in
    (match extract_github_org_repo url with
     | None -> Error (Printf.sprintf "Cannot parse GitHub org/repo from URL: %s" url)
     | Some org_repo ->
       if List.mem org_repo denied_lc
       then Error (Printf.sprintf "Repository '%s' is in the denied list" org_repo)
       else (
         match String.split_on_char '/' org_repo with
         | _org :: _ when List.length allowed_lc = 0 -> Ok ()
         | org :: _ when List.mem org allowed_lc -> Ok ()
         | org :: _ ->
           Error
             (Printf.sprintf
                "GitHub org '%s' not in allowed list: %s. Use the actual GitHub \
                 owner from the clone URL; do not infer an org from local \
                 workspace path segments."
                org
                (String.concat ", " allowed))
         | [] -> Error (Printf.sprintf "Cannot parse GitHub org/repo from URL: %s" url)))
;;
