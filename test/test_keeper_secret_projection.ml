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

let secret_root_default ~base ~keeper_name =
  Filename.concat
    (Filename.concat (Filename.concat base Common.masc_dirname) "secrets")
    (Workspace_utils.safe_filename keeper_name)
;;

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
       Alcotest.(check string)
         "env file content"
         "GH_TOKEN=ghs_projected_secret\n"
         (read_file env_file);
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
            Alcotest.(check string) "override env content" "GH_TOKEN=override\n"
              (read_file env_file);
            projection.cleanup ()))
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
  Alcotest.(check int) "file count" 0 (json_int "file_count" json)
;;

let test_dashboard_status_redacts_values () =
  let base = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  with_env "MASC_SECRET_DIR" "" @@ fun () ->
  let root = secret_root_default ~base ~keeper_name:"minjae" in
  let token_path = Filename.concat (Filename.concat root "env") "GH_TOKEN" in
  let ssh_path =
    Filename.concat
      (Filename.concat root "files")
      "home/keeper/.ssh/id_ed25519"
  in
  write_file token_path "ghs_dashboard_secret\n";
  write_file ssh_path "PRIVATE KEY";
  let json =
    Keeper_secret_projection.dashboard_status_json
      ~base_path:base
      ~keeper_name:"minjae"
  in
  let raw = Yojson.Safe.to_string json in
  Alcotest.(check string) "status" "ready" (json_string "status" json);
  Alcotest.(check int) "env count" 1 (json_int "env_count" json);
  Alcotest.(check int) "file count" 1 (json_int "file_count" json);
  Alcotest.(check (list string)) "env names" [ "GH_TOKEN" ]
    (json_string_list "env_names" json);
  Alcotest.(check bool) "raw env value redacted" false
    (contains_substring raw "ghs_dashboard_secret")
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
        ; Alcotest.test_case "env value leading hash rejects" `Quick
            test_env_value_leading_hash_rejects
        ] )
    ]
;;
