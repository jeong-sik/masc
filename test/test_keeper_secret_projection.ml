module Keeper_secret_projection = Masc.Keeper_secret_projection

let with_env key value f =
  let prior = Sys.getenv_opt key in
  Unix.putenv key value;
  Fun.protect
    ~finally:(fun () ->
      match prior with
      | Some v -> Unix.putenv key v
      | None -> Unix.putenv key "")
    f
;;

let temp_dir () =
  let d = Filename.temp_file "keeper_secret_projection_" "" in
  Unix.unlink d;
  Unix.mkdir d 0o755;
  d
;;

let rec ensure_dir path =
  if path = "" || path = "." || path = "/" then ()
  else if Sys.file_exists path then ()
  else (
    let parent = Filename.dirname path in
    if parent <> path then ensure_dir parent;
    Unix.mkdir path 0o755)
;;

let cleanup_dir dir =
  let rec rm path =
    match Unix.lstat path with
    | { Unix.st_kind = Unix.S_DIR; _ } ->
      Array.iter (fun name -> rm (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path
    | _ -> Unix.unlink path
    | exception Unix.Unix_error _ -> ()
  in
  try rm dir with
  | _ -> ()
;;

let write_file path content =
  ensure_dir (Filename.dirname path);
  let oc = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out oc) @@ fun () ->
  output_string oc content
;;

let read_file path =
  let ic = open_in_bin path in
  Fun.protect ~finally:(fun () -> close_in ic) @@ fun () ->
  really_input_string ic (in_channel_length ic)
;;

let contains_substring haystack needle =
  let hlen = String.length haystack in
  let nlen = String.length needle in
  let rec loop i =
    if nlen = 0 then true
    else if i + nlen > hlen then false
    else if String.sub haystack i nlen = needle then true
    else loop (i + 1)
  in
  loop 0
;;

let assoc_member name = function
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None
;;

let json_string name json =
  match assoc_member name json with
  | Some (`String value) -> value
  | _ -> Alcotest.failf "missing string field %s" name
;;

let json_int name json =
  match assoc_member name json with
  | Some (`Int value) -> value
  | _ -> Alcotest.failf "missing int field %s" name
;;

let json_bool name json =
  match assoc_member name json with
  | Some (`Bool value) -> value
  | _ -> Alcotest.failf "missing bool field %s" name
;;

let json_list name json =
  match assoc_member name json with
  | Some (`List values) -> values
  | _ -> Alcotest.failf "missing list field %s" name
;;

let json_string_list name json =
  match assoc_member name json with
  | Some (`List values) ->
    List.map
      (function
        | `String value -> value
        | _ -> Alcotest.failf "non-string value in %s" name)
      values
  | _ -> Alcotest.failf "missing string list field %s" name
;;

let rec env_file_arg = function
  | "--env-file" :: path :: _ -> Some path
  | _ :: rest -> env_file_arg rest
  | [] -> None
;;

let env_value key env =
  Array.to_list env
  |> List.find_map (fun entry ->
    match String.index_opt entry '=' with
    | None -> None
    | Some idx ->
      let entry_key = String.sub entry 0 idx in
      if String.equal entry_key key
      then
        Some
          (String.sub entry (idx + 1) (String.length entry - idx - 1))
      else None)
;;

let secret_root_default ~base ~keeper_name =
  Filename.concat
    (Filename.concat (Filename.concat base Common.masc_dirname) "secrets")
    (Workspace_utils.safe_filename keeper_name)
;;

let base_secret_root_default ~base = secret_root_default ~base ~keeper_name:"base"

let test_missing_secret_dir_is_noop () =
  let base = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  with_env "MASC_SECRET_DIR" "" @@ fun () ->
  match
    Keeper_secret_projection.docker_args_for_keeper
      ~base_path:base
      ~keeper_name:"minjae"
      ~container_name:"container"
  with
  | Error err -> Alcotest.fail err
  | Ok projection ->
    Alcotest.(check (list string)) "no docker args" [] projection.docker_args;
    projection.cleanup ()
;;

let test_env_and_files_project_to_docker_args () =
  let base = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  with_env "MASC_SECRET_DIR" "" @@ fun () ->
  let root = secret_root_default ~base ~keeper_name:"MinJae" in
  let token_path = Filename.concat (Filename.concat root "env") "GH_TOKEN" in
  let ssh_path =
    Filename.concat
      (Filename.concat root "files")
      "home/keeper/.ssh/id_ed25519"
  in
  write_file token_path "ghs_projected_secret\n";
  write_file ssh_path "PRIVATE KEY";
  match
    Keeper_secret_projection.docker_args_for_keeper
      ~base_path:base
      ~keeper_name:"MinJae"
      ~container_name:"container"
  with
  | Error err -> Alcotest.fail err
  | Ok projection ->
    let args = String.concat " " projection.docker_args in
    Alcotest.(check bool) "raw secret not in argv" false
      (contains_substring args "ghs_projected_secret");
    Alcotest.(check bool) "ssh file mounted read-only" true
      (contains_substring
         args
         (ssh_path ^ ":/home/keeper/.ssh/id_ed25519:ro"));
    (match env_file_arg projection.docker_args with
     | None -> Alcotest.fail "missing --env-file"
     | Some env_file ->
       let env = read_file env_file in
       Alcotest.(check bool)
         "env file content"
         true
         (contains_substring env "GH_TOKEN=ghs_projected_secret\n");
       Alcotest.(check bool) "git config env added" true
         (contains_substring env "GIT_CONFIG_GLOBAL=");
       projection.cleanup ();
       Alcotest.(check bool) "env file cleaned up" false (Sys.file_exists env_file))
;;

let test_secret_dir_override_uses_keeper_subdir () =
  let base = temp_dir () in
  let override_root = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      cleanup_dir base;
      cleanup_dir override_root)
    (fun () ->
       with_env "MASC_SECRET_DIR" override_root @@ fun () ->
       let keeper_root =
         Filename.concat override_root (Workspace_utils.safe_filename "MinJae")
       in
       write_file (Filename.concat (Filename.concat keeper_root "env") "GH_TOKEN") "override";
       match
         Keeper_secret_projection.docker_args_for_keeper
           ~base_path:base
           ~keeper_name:"MinJae"
           ~container_name:"container"
       with
       | Error err -> Alcotest.fail err
       | Ok projection ->
         (match env_file_arg projection.docker_args with
          | None -> Alcotest.fail "missing --env-file"
          | Some env_file ->
            Alcotest.(check bool) "override env content" true
              (contains_substring (read_file env_file) "GH_TOKEN=override\n");
            projection.cleanup ()))
;;

let test_base_secret_env_and_files_project_to_keeper_docker_args () =
  let base = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  with_env "MASC_SECRET_DIR" "" @@ fun () ->
  let root = base_secret_root_default ~base in
  let token_path = Filename.concat (Filename.concat root "env") "GH_TOKEN" in
  let ssh_path =
    Filename.concat
      (Filename.concat root "files")
      "home/keeper/.ssh/id_ed25519"
  in
  write_file token_path "base-token\n";
  write_file ssh_path "BASE PRIVATE KEY";
  match
    Keeper_secret_projection.docker_args_for_keeper
      ~base_path:base
      ~keeper_name:"idealist"
      ~container_name:"container"
  with
  | Error err -> Alcotest.fail err
  | Ok projection ->
    (match env_file_arg projection.docker_args with
     | None -> Alcotest.fail "missing --env-file"
     | Some env_file ->
       let env = read_file env_file in
       Alcotest.(check bool) "base gh token projected" true
         (contains_substring env "GH_TOKEN=base-token\n");
       Alcotest.(check bool) "git config env projected" true
         (contains_substring env "GIT_CONFIG_GLOBAL="));
    let args = String.concat " " projection.docker_args in
    Alcotest.(check bool) "base ssh file mounted" true
      (contains_substring args (ssh_path ^ ":/home/keeper/.ssh/id_ed25519:ro"));
    Alcotest.(check bool) "generated gitconfig mounted" true
      (contains_substring args ":/tmp/masc-runtime/.masc/gitconfig:ro");
    projection.cleanup ()
;;

let test_keeper_secret_overrides_base_secret_entries () =
  let base = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  with_env "MASC_SECRET_DIR" "" @@ fun () ->
  let base_root = base_secret_root_default ~base in
  let keeper_root = secret_root_default ~base ~keeper_name:"idealist" in
  let base_ssh =
    Filename.concat
      (Filename.concat base_root "files")
      "home/keeper/.ssh/id_ed25519"
  in
  let keeper_ssh =
    Filename.concat
      (Filename.concat keeper_root "files")
      "home/keeper/.ssh/id_ed25519"
  in
  write_file (Filename.concat (Filename.concat base_root "env") "GH_TOKEN") "base-token";
  write_file (Filename.concat (Filename.concat keeper_root "env") "GH_TOKEN") "keeper-token";
  write_file base_ssh "BASE PRIVATE KEY";
  write_file keeper_ssh "KEEPER PRIVATE KEY";
  match
    Keeper_secret_projection.docker_args_for_keeper
      ~base_path:base
      ~keeper_name:"idealist"
      ~container_name:"container"
  with
  | Error err -> Alcotest.fail err
  | Ok projection ->
    (match env_file_arg projection.docker_args with
     | None -> Alcotest.fail "missing --env-file"
     | Some env_file ->
       let env = read_file env_file in
       Alcotest.(check bool) "keeper token wins" true
         (contains_substring env "GH_TOKEN=keeper-token\n");
       Alcotest.(check bool) "base token omitted" false
         (contains_substring env "GH_TOKEN=base-token\n"));
    let args = String.concat " " projection.docker_args in
    Alcotest.(check bool) "keeper ssh mount wins" true
      (contains_substring args (keeper_ssh ^ ":/home/keeper/.ssh/id_ed25519:ro"));
    Alcotest.(check bool) "base ssh mount omitted" false
      (contains_substring args (base_ssh ^ ":/home/keeper/.ssh/id_ed25519:ro"));
    projection.cleanup ()
;;

let test_local_env_missing_secret_dir_is_scrubbed () =
  let base = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  with_env "MASC_SECRET_DIR" "" @@ fun () ->
  let host_env =
    [| "PATH=/usr/bin"
     ; "GH_TOKEN=ambient-gh"
     ; "GITHUB_TOKEN=ambient-github"
     ; "GH_CONFIG_DIR=/Users/operator/.config/gh"
     ; "SSH_AUTH_SOCK=/tmp/operator-agent.sock"
     ; "GIT_TERMINAL_PROMPT=1"
    |]
  in
  match
    Keeper_secret_projection.local_env_for_keeper
      ~host_env
      ~base_path:base
      ~keeper_name:"minjae"
      ()
  with
  | Error err -> Alcotest.fail err
  | Ok None -> Alcotest.fail "expected scrubbed local env for missing secret root"
  | Ok (Some env) ->
    Alcotest.(check (option string)) "ambient gh token stripped" None
      (env_value "GH_TOKEN" env);
    Alcotest.(check (option string)) "ambient github token stripped" None
      (env_value "GITHUB_TOKEN" env);
    Alcotest.(check bool) "ambient gh config not inherited" true
      (env_value "GH_CONFIG_DIR" env <> Some "/Users/operator/.config/gh");
    if Sys.file_exists "/var/empty" && Sys.is_directory "/var/empty"
    then
      Alcotest.(check (option string))
        "empty gh config fallback"
        (Some "/var/empty")
        (env_value "GH_CONFIG_DIR" env);
    Alcotest.(check (option string)) "ambient ssh agent stripped" None
      (env_value "SSH_AUTH_SOCK" env);
    Alcotest.(check (option string)) "noninteractive git prompt injected" (Some "0")
      (env_value "GIT_TERMINAL_PROMPT" env);
    Alcotest.(check (option string)) "safe PATH preserved" (Some "/usr/bin")
      (env_value "PATH" env)
;;

let test_local_env_uses_keeper_secret_env_without_ambient_credentials () =
  let base = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  with_env "MASC_SECRET_DIR" "" @@ fun () ->
  let root = secret_root_default ~base ~keeper_name:"MinJae" in
  let env_root = Filename.concat root "env" in
  let files_root = Filename.concat root "files" in
  write_file (Filename.concat env_root "GH_TOKEN") "keeper-token\n";
  write_file
    (Filename.concat env_root "GIT_SSH_COMMAND")
    ("ssh -i " ^ Filename.concat files_root "ssh/id_ed25519");
  write_file (Filename.concat files_root "ssh/id_ed25519") "PRIVATE KEY";
  let host_env =
    [| "PATH=/usr/bin"
     ; "HOME=/Users/operator"
     ; "FOO=bar"
     ; "GH_TOKEN=ambient-gh"
     ; "GITHUB_TOKEN=ambient-github"
     ; "GH_CONFIG_DIR=/Users/operator/.config/gh"
     ; "SSH_AUTH_SOCK=/tmp/operator-agent.sock"
     ; "GIT_TERMINAL_PROMPT=1"
    |]
  in
  match
    Keeper_secret_projection.local_env_for_keeper
      ~host_env
      ~base_path:base
      ~keeper_name:"MinJae"
      ()
  with
  | Error err -> Alcotest.fail err
  | Ok None -> Alcotest.fail "expected local env projection"
  | Ok (Some env) ->
    Alcotest.(check (option string))
      "keeper token wins"
      (Some "keeper-token")
      (env_value "GH_TOKEN" env);
    Alcotest.(check (option string))
      "ambient github token stripped"
      None
      (env_value "GITHUB_TOKEN" env);
    Alcotest.(check bool)
      "ambient gh config not inherited"
      true
      (env_value "GH_CONFIG_DIR" env <> Some "/Users/operator/.config/gh");
    if Sys.file_exists "/var/empty" && Sys.is_directory "/var/empty"
    then
      Alcotest.(check (option string))
        "empty gh config fallback"
        (Some "/var/empty")
        (env_value "GH_CONFIG_DIR" env);
    Alcotest.(check (option string))
      "ambient ssh agent stripped"
      None
      (env_value "SSH_AUTH_SOCK" env);
    Alcotest.(check (option string))
      "noninteractive git prompt injected"
      (Some "0")
      (env_value "GIT_TERMINAL_PROMPT" env);
    Alcotest.(check (option string))
      "keeper ssh command projected"
      (Some ("ssh -i " ^ Filename.concat files_root "ssh/id_ed25519"))
      (env_value "GIT_SSH_COMMAND" env);
    Alcotest.(check (option string))
      "unsafe ambient variable stripped"
      None
      (env_value "FOO" env);
    Alcotest.(check (option string))
      "safe PATH preserved"
      (Some "/usr/bin")
      (env_value "PATH" env)
;;

let test_local_env_inherits_base_secret_and_sets_git_config_global () =
  let base = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  with_env "MASC_SECRET_DIR" "" @@ fun () ->
  let root = base_secret_root_default ~base in
  write_file (Filename.concat (Filename.concat root "env") "GH_TOKEN") "base-token\n";
  let host_env = [| "PATH=/usr/bin"; "HOME=/Users/operator" |] in
  match
    Keeper_secret_projection.local_env_for_keeper
      ~host_env
      ~base_path:base
      ~keeper_name:"idealist"
      ()
  with
  | Error err -> Alcotest.fail err
  | Ok None -> Alcotest.fail "expected local env projection"
  | Ok (Some env) ->
    Alcotest.(check (option string))
      "base token projected"
      (Some "base-token")
      (env_value "GH_TOKEN" env);
    (match env_value "GIT_CONFIG_GLOBAL" env with
     | None -> Alcotest.fail "missing GIT_CONFIG_GLOBAL"
     | Some git_config ->
       Alcotest.(check bool) "git config under keeper playground" true
         (contains_substring git_config ".masc/playground/idealist/.gitconfig");
       Alcotest.(check bool) "git config file exists" true
         (Sys.file_exists git_config);
       Alcotest.(check bool) "git helper configured" true
         (contains_substring (read_file git_config) "gh auth git-credential"))
;;

let test_invalid_env_name_rejects () =
  let base = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  with_env "MASC_SECRET_DIR" "" @@ fun () ->
  let root = secret_root_default ~base ~keeper_name:"minjae" in
  write_file (Filename.concat (Filename.concat root "env") "BAD-NAME") "x";
  match
    Keeper_secret_projection.docker_args_for_keeper
      ~base_path:base
      ~keeper_name:"minjae"
      ~container_name:"container"
  with
  | Ok _ -> Alcotest.fail "expected invalid env name rejection"
  | Error err ->
    Alcotest.(check bool) "mentions invalid env name" true
      (contains_substring err "invalid keeper secret env name")
;;

let test_symlink_file_rejects () =
  let base = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  with_env "MASC_SECRET_DIR" "" @@ fun () ->
  let root = secret_root_default ~base ~keeper_name:"minjae" in
  let outside = Filename.concat base "outside-secret" in
  write_file outside "x";
  let link_path =
    Filename.concat (Filename.concat root "files") "home/keeper/.ssh/id_ed25519"
  in
  ensure_dir (Filename.dirname link_path);
  Unix.symlink outside link_path;
  match
    Keeper_secret_projection.docker_args_for_keeper
      ~base_path:base
      ~keeper_name:"minjae"
      ~container_name:"container"
  with
  | Ok _ -> Alcotest.fail "expected symlink rejection"
  | Error err ->
    Alcotest.(check bool) "mentions symlink" true
      (contains_substring err "symlink")
;;

let test_symlink_env_dir_rejects () =
  let base = temp_dir () in
  let outside = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      cleanup_dir base;
      cleanup_dir outside)
    (fun () ->
       with_env "MASC_SECRET_DIR" "" @@ fun () ->
       write_file (Filename.concat outside "GH_TOKEN") "x";
       let root = secret_root_default ~base ~keeper_name:"minjae" in
       let env_root = Filename.concat root "env" in
       ensure_dir root;
       Unix.symlink outside env_root;
       match
         Keeper_secret_projection.docker_args_for_keeper
           ~base_path:base
           ~keeper_name:"minjae"
           ~container_name:"container"
       with
       | Ok _ -> Alcotest.fail "expected env directory symlink rejection"
       | Error err ->
         Alcotest.(check bool) "mentions symlink" true
           (contains_substring err "symlink"))
;;

let test_dashboard_status_absent_root () =
  let base = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  with_env "MASC_SECRET_DIR" "" @@ fun () ->
  let json =
    Keeper_secret_projection.dashboard_status_json
      ~base_path:base
      ~keeper_name:"minjae"
  in
  Alcotest.(check string) "status" "absent" (json_string "status" json);
  Alcotest.(check int) "env count" 0 (json_int "env_count" json);
  Alcotest.(check int) "file count" 0 (json_int "file_count" json);
  let roots = json_list "effective_roots" json in
  Alcotest.(check int) "base and keeper roots reported" 2 (List.length roots);
  (match roots with
   | base_root :: keeper_root :: [] ->
     Alcotest.(check string)
       "base root path"
       (base_secret_root_default ~base)
       (json_string "root" base_root);
     Alcotest.(check string)
       "keeper root path"
       (secret_root_default ~base ~keeper_name:"minjae")
       (json_string "root" keeper_root);
     Alcotest.(check string) "base root absent" "absent"
       (json_string "status" base_root);
     Alcotest.(check bool) "keeper root not configured" false
       (json_bool "configured" keeper_root)
   | _ -> Alcotest.fail "expected exactly base and keeper roots")
;;

let test_dashboard_status_redacts_values () =
  let base = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  with_env "MASC_SECRET_DIR" "" @@ fun () ->
  let base_root = base_secret_root_default ~base in
  let root = secret_root_default ~base ~keeper_name:"minjae" in
  let shared_token_path = Filename.concat (Filename.concat base_root "env") "GITHUB_TOKEN" in
  let token_path = Filename.concat (Filename.concat root "env") "GH_TOKEN" in
  let ssh_path =
    Filename.concat
      (Filename.concat root "files")
      "home/keeper/.ssh/id_ed25519"
  in
  write_file shared_token_path "ghs_shared_dashboard_secret\n";
  write_file token_path "ghs_dashboard_secret\n";
  write_file ssh_path "PRIVATE KEY";
  let json =
    Keeper_secret_projection.dashboard_status_json
      ~base_path:base
      ~keeper_name:"minjae"
  in
  let raw = Yojson.Safe.to_string json in
  Alcotest.(check string) "status" "ready" (json_string "status" json);
  Alcotest.(check int) "env count" 2 (json_int "env_count" json);
  Alcotest.(check int) "file count" 1 (json_int "file_count" json);
  Alcotest.(check (list string)) "env names" [ "GITHUB_TOKEN"; "GH_TOKEN" ]
    (json_string_list "env_names" json);
  Alcotest.(check bool) "raw env value redacted" false
    (contains_substring raw "ghs_dashboard_secret");
  Alcotest.(check bool) "shared env value redacted" false
    (contains_substring raw "ghs_shared_dashboard_secret");
  let roots = json_list "effective_roots" json in
  Alcotest.(check int) "effective root count" 2 (List.length roots);
  (match roots with
   | base_projection :: keeper_projection :: [] ->
     Alcotest.(check string) "base status" "ready"
       (json_string "status" base_projection);
     Alcotest.(check int) "base env count" 1
       (json_int "env_count" base_projection);
     Alcotest.(check int) "keeper env count" 1
       (json_int "env_count" keeper_projection);
     Alcotest.(check int) "keeper file count" 1
       (json_int "file_count" keeper_projection)
   | _ -> Alcotest.fail "expected exactly base and keeper projections")
;;

let test_dashboard_status_reports_projection_error () =
  let base = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  with_env "MASC_SECRET_DIR" "" @@ fun () ->
  let root = secret_root_default ~base ~keeper_name:"minjae" in
  write_file (Filename.concat (Filename.concat root "env") "BAD-NAME") "x";
  let json =
    Keeper_secret_projection.dashboard_status_json
      ~base_path:base
      ~keeper_name:"minjae"
  in
  Alcotest.(check string) "status" "error" (json_string "status" json);
  Alcotest.(check bool) "mentions invalid env name" true
    (contains_substring (Yojson.Safe.to_string json) "invalid keeper secret env name")
;;

let test_set_and_delete_env_entry_updates_projection () =
  let base = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  with_env "MASC_SECRET_DIR" "" @@ fun () ->
  let base_root = base_secret_root_default ~base in
  let keeper_root = secret_root_default ~base ~keeper_name:"minjae" in
  let shared_path = Filename.concat (Filename.concat base_root "env") "GH_TOKEN" in
  let keeper_path = Filename.concat (Filename.concat keeper_root "env") "GH_TOKEN" in
  (match
     Keeper_secret_projection.set_env_entry
       ~base_path:base
       ~keeper_name:"minjae"
       ~scope:Keeper_secret_projection.Shared_secret
       ~name:"GH_TOKEN"
       ~value:"ghs_shared_from_ui\n"
   with
   | Ok () -> ()
   | Error msg -> Alcotest.fail msg);
  (match
     Keeper_secret_projection.set_env_entry
       ~base_path:base
       ~keeper_name:"minjae"
       ~scope:Keeper_secret_projection.Keeper_secret
       ~name:"GH_TOKEN"
       ~value:"ghs_keeper_from_ui"
   with
   | Ok () -> ()
   | Error msg -> Alcotest.fail msg);
  Alcotest.(check string) "shared value normalized" "ghs_shared_from_ui"
    (read_file shared_path);
  Alcotest.(check string) "keeper value" "ghs_keeper_from_ui"
    (read_file keeper_path);
  let json =
    Keeper_secret_projection.dashboard_status_json
      ~base_path:base
      ~keeper_name:"minjae"
  in
  Alcotest.(check string) "status" "ready" (json_string "status" json);
  Alcotest.(check int) "effective env count" 1 (json_int "env_count" json);
  Alcotest.(check bool) "shared value redacted" false
    (contains_substring (Yojson.Safe.to_string json) "ghs_shared_from_ui");
  Alcotest.(check bool) "keeper value redacted" false
    (contains_substring (Yojson.Safe.to_string json) "ghs_keeper_from_ui");
  (match
     Keeper_secret_projection.delete_env_entry
       ~base_path:base
       ~keeper_name:"minjae"
       ~scope:Keeper_secret_projection.Keeper_secret
       ~name:"GH_TOKEN"
   with
   | Ok () -> ()
   | Error msg -> Alcotest.fail msg);
  Alcotest.(check bool) "keeper file deleted" false (Sys.file_exists keeper_path);
  let inherited_json =
    Keeper_secret_projection.dashboard_status_json
      ~base_path:base
      ~keeper_name:"minjae"
  in
  Alcotest.(check int) "inherits shared env" 1 (json_int "env_count" inherited_json);
  (match
     Keeper_secret_projection.delete_env_entry
       ~base_path:base
       ~keeper_name:"minjae"
       ~scope:Keeper_secret_projection.Shared_secret
       ~name:"GH_TOKEN"
   with
   | Ok () -> ()
   | Error msg -> Alcotest.fail msg);
  Alcotest.(check bool) "shared file deleted" false (Sys.file_exists shared_path)
;;

let test_set_env_entry_rejects_invalid_inputs () =
  let base = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  with_env "MASC_SECRET_DIR" "" @@ fun () ->
  (match
     Keeper_secret_projection.set_env_entry
       ~base_path:base
       ~keeper_name:"minjae"
       ~scope:Keeper_secret_projection.Keeper_secret
       ~name:"BAD-NAME"
       ~value:"secret"
   with
   | Ok () -> Alcotest.fail "expected invalid env name rejection"
   | Error msg ->
     Alcotest.(check bool) "mentions env name" true
       (contains_substring msg "invalid keeper secret env name"));
  (match
     Keeper_secret_projection.set_env_entry
       ~base_path:base
       ~keeper_name:"minjae"
       ~scope:Keeper_secret_projection.Keeper_secret
       ~name:"GH_TOKEN"
       ~value:"line1\nline2"
   with
   | Ok () -> Alcotest.fail "expected multiline value rejection"
   | Error msg ->
     Alcotest.(check bool) "mentions single-line" true
       (contains_substring msg "single-line"))
;;

let test_set_and_delete_file_entry_updates_projection () =
  let base = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  with_env "MASC_SECRET_DIR" "" @@ fun () ->
  let base_root = base_secret_root_default ~base in
  let keeper_root = secret_root_default ~base ~keeper_name:"minjae" in
  let container_path = "/home/keeper/.ssh/id_ed25519" in
  let shared_path =
    Filename.concat
      (Filename.concat base_root "files")
      "home/keeper/.ssh/id_ed25519"
  in
  let keeper_path =
    Filename.concat
      (Filename.concat keeper_root "files")
      "home/keeper/.ssh/id_ed25519"
  in
  (match
     Keeper_secret_projection.set_file_entry
       ~base_path:base
       ~keeper_name:"minjae"
       ~scope:Keeper_secret_projection.Shared_secret
       ~container_path
       ~value:"SHARED\nPRIVATE\nKEY\n"
   with
   | Ok () -> ()
   | Error msg -> Alcotest.fail msg);
  (match
     Keeper_secret_projection.set_file_entry
       ~base_path:base
       ~keeper_name:"minjae"
       ~scope:Keeper_secret_projection.Keeper_secret
       ~container_path
       ~value:"KEEPER\nPRIVATE\nKEY\n"
   with
   | Ok () -> ()
   | Error msg -> Alcotest.fail msg);
  Alcotest.(check string) "shared file preserves newlines" "SHARED\nPRIVATE\nKEY\n"
    (read_file shared_path);
  Alcotest.(check string) "keeper file preserves newlines" "KEEPER\nPRIVATE\nKEY\n"
    (read_file keeper_path);
  let json =
    Keeper_secret_projection.dashboard_status_json
      ~base_path:base
      ~keeper_name:"minjae"
  in
  Alcotest.(check string) "status" "ready" (json_string "status" json);
  Alcotest.(check int) "effective file count" 1 (json_int "file_count" json);
  Alcotest.(check bool) "shared file value redacted" false
    (contains_substring (Yojson.Safe.to_string json) "SHARED");
  Alcotest.(check bool) "keeper file value redacted" false
    (contains_substring (Yojson.Safe.to_string json) "KEEPER");
  (match
     Keeper_secret_projection.docker_args_for_keeper
       ~base_path:base
       ~keeper_name:"minjae"
       ~container_name:"container"
   with
   | Error msg -> Alcotest.fail msg
   | Ok projection ->
     let args = String.concat " " projection.docker_args in
     Alcotest.(check bool) "keeper file mount wins" true
       (contains_substring args (keeper_path ^ ":" ^ container_path ^ ":ro"));
     Alcotest.(check bool) "shared file mount omitted" false
       (contains_substring args (shared_path ^ ":" ^ container_path ^ ":ro"));
     projection.cleanup ());
  (match
     Keeper_secret_projection.delete_file_entry
       ~base_path:base
       ~keeper_name:"minjae"
       ~scope:Keeper_secret_projection.Keeper_secret
       ~container_path
   with
   | Ok () -> ()
   | Error msg -> Alcotest.fail msg);
  Alcotest.(check bool) "keeper file deleted" false (Sys.file_exists keeper_path);
  let inherited_json =
    Keeper_secret_projection.dashboard_status_json
      ~base_path:base
      ~keeper_name:"minjae"
  in
  Alcotest.(check int) "inherits shared file" 1 (json_int "file_count" inherited_json);
  (match
     Keeper_secret_projection.docker_args_for_keeper
       ~base_path:base
       ~keeper_name:"minjae"
       ~container_name:"container"
   with
   | Error msg -> Alcotest.fail msg
   | Ok projection ->
     let args = String.concat " " projection.docker_args in
     Alcotest.(check bool) "shared file mount inherited" true
       (contains_substring args (shared_path ^ ":" ^ container_path ^ ":ro"));
     projection.cleanup ());
  (match
     Keeper_secret_projection.delete_file_entry
       ~base_path:base
       ~keeper_name:"minjae"
       ~scope:Keeper_secret_projection.Shared_secret
       ~container_path
   with
   | Ok () -> ()
   | Error msg -> Alcotest.fail msg);
  Alcotest.(check bool) "shared file deleted" false (Sys.file_exists shared_path)
;;

let test_set_file_entry_rejects_invalid_inputs () =
  let base = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  with_env "MASC_SECRET_DIR" "" @@ fun () ->
  (match
     Keeper_secret_projection.set_file_entry
       ~base_path:base
       ~keeper_name:"minjae"
       ~scope:Keeper_secret_projection.Keeper_secret
       ~container_path:"relative"
       ~value:"secret"
   with
   | Ok () -> Alcotest.fail "expected relative path rejection"
   | Error msg ->
     Alcotest.(check bool) "mentions absolute path" true
       (contains_substring msg "absolute"));
  (match
     Keeper_secret_projection.set_file_entry
       ~base_path:base
       ~keeper_name:"minjae"
       ~scope:Keeper_secret_projection.Keeper_secret
       ~container_path:"/home/../secret"
       ~value:"secret"
   with
   | Ok () -> Alcotest.fail "expected traversal rejection"
   | Error msg ->
     Alcotest.(check bool) "mentions path component" true
       (contains_substring msg "invalid keeper secret file path component"));
  (match
     Keeper_secret_projection.set_file_entry
       ~base_path:base
       ~keeper_name:"minjae"
       ~scope:Keeper_secret_projection.Keeper_secret
       ~container_path:"/home/keeper/secret"
       ~value:"abc\000def"
   with
   | Ok () -> Alcotest.fail "expected NUL value rejection"
   | Error msg ->
     Alcotest.(check bool) "mentions NUL" true (contains_substring msg "NUL"))
;;

let test_env_value_leading_hash_rejects () =
  let base = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  with_env "MASC_SECRET_DIR" "" @@ fun () ->
  let root = secret_root_default ~base ~keeper_name:"minjae" in
  write_file (Filename.concat (Filename.concat root "env") "GH_TOKEN") "#starts_with_hash";
  match
    Keeper_secret_projection.docker_args_for_keeper
      ~base_path:base
      ~keeper_name:"minjae"
      ~container_name:"container"
  with
  | Ok _ -> Alcotest.fail "expected leading-hash env value rejection"
  | Error err ->
    Alcotest.(check bool) "mentions docker env-file comment" true
      (contains_substring err "docker --env-file")
;;

let () =
  Alcotest.run
    "keeper secret projection"
    [ ( "projection"
      , [ Alcotest.test_case "missing secret dir is noop" `Quick
            test_missing_secret_dir_is_noop
        ; Alcotest.test_case "env and files project to docker args" `Quick
            test_env_and_files_project_to_docker_args
        ; Alcotest.test_case "MASC_SECRET_DIR uses keeper subdir" `Quick
            test_secret_dir_override_uses_keeper_subdir
        ; Alcotest.test_case "base secret projects to keeper docker args" `Quick
            test_base_secret_env_and_files_project_to_keeper_docker_args
        ; Alcotest.test_case "keeper secret overrides base secret entries" `Quick
            test_keeper_secret_overrides_base_secret_entries
        ; Alcotest.test_case "local env missing secret dir is scrubbed" `Quick
            test_local_env_missing_secret_dir_is_scrubbed
        ; Alcotest.test_case "local env uses keeper env without ambient creds" `Quick
            test_local_env_uses_keeper_secret_env_without_ambient_credentials
        ; Alcotest.test_case "local env inherits base secret and sets git config" `Quick
            test_local_env_inherits_base_secret_and_sets_git_config_global
        ; Alcotest.test_case "invalid env name rejects" `Quick
            test_invalid_env_name_rejects
        ; Alcotest.test_case "symlink file rejects" `Quick test_symlink_file_rejects
        ; Alcotest.test_case "symlink env dir rejects" `Quick
            test_symlink_env_dir_rejects
        ; Alcotest.test_case "dashboard status absent root" `Quick
            test_dashboard_status_absent_root
        ; Alcotest.test_case "dashboard status redacts values" `Quick
            test_dashboard_status_redacts_values
        ; Alcotest.test_case "dashboard status reports projection error" `Quick
            test_dashboard_status_reports_projection_error
        ; Alcotest.test_case "set/delete env entry updates projection" `Quick
            test_set_and_delete_env_entry_updates_projection
        ; Alcotest.test_case "set env entry rejects invalid inputs" `Quick
            test_set_env_entry_rejects_invalid_inputs
        ; Alcotest.test_case "set/delete file entry updates projection" `Quick
            test_set_and_delete_file_entry_updates_projection
        ; Alcotest.test_case "set file entry rejects invalid inputs" `Quick
            test_set_file_entry_rejects_invalid_inputs
        ; Alcotest.test_case "env value leading hash rejects" `Quick
            test_env_value_leading_hash_rejects
        ] )
    ]
;;
