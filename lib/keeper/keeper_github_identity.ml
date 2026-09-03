let github_token_env_names =
  [ "GH_TOKEN"
  ; "GITHUB_TOKEN"
  ; "GH_ENTERPRISE_TOKEN"
  ; "GITHUB_ENTERPRISE_TOKEN"
  ]
;;

type auth_result =
  { authenticated : bool
  ; login : string option
  ; error : string option
  }

type observation =
  { keeper : string
  ; hostname : string
  ; config_dir : string
  ; projected_token_env_names : string list
  ; stored : auth_result
  ; effective : auth_result
  ; effective_probe_scope : [ `Host_process_credential_only ]
  ; checked_at_unix : float
  }

let config_dir_name = "github-cli"

let config_dir ~config ~keeper_name =
  Filename.concat
    (Filename.concat (Workspace.keepers_runtime_dir config) keeper_name)
    config_dir_name
;;

(* Base-path variant for callers that hold only [base_path] (e.g. the chat
   store's redaction snapshot). Default-cluster on purpose, matching
   [Common.keepers_runtime_dir_of_base]: the chat store's secret projection
   roots are already base-path scoped, so this keeps both snapshot sources
   on the same cluster resolution. *)
let config_dir_of_base_path ~base_path ~keeper_name =
  Filename.concat
    (Filename.concat (Common.keepers_runtime_dir_of_base ~base_path) keeper_name)
    config_dir_name
;;

let secret_files_of_base_path ~base_path ~keeper_name =
  [ Filename.concat (config_dir_of_base_path ~base_path ~keeper_name) "hosts.yml" ]
;;

let container_config_dir ~container_masc_dir ~keeper_name =
  Filename.concat
    (Filename.concat (Filename.concat container_masc_dir "keepers") keeper_name)
    config_dir_name
;;

let file_kind_to_string = function
  | Unix.S_REG -> "regular file"
  | Unix.S_DIR -> "directory"
  | Unix.S_CHR -> "character device"
  | Unix.S_BLK -> "block device"
  | Unix.S_LNK -> "symbolic link"
  | Unix.S_FIFO -> "FIFO"
  | Unix.S_SOCK -> "socket"
;;

let lstat_opt path =
  try Ok (Some (Unix.lstat path)) with
  | Unix.Unix_error (Unix.ENOENT, _, _) -> Ok None
  | Unix.Unix_error (error, operation, target) ->
    Error
      (Printf.sprintf
         "cannot inspect GitHub CLI path %s: %s(%s): %s"
         path
         operation
         target
         (Unix.error_message error))
;;

let require_directory path =
  match lstat_opt path with
  | Error _ as error -> error
  | Ok None -> Error (Printf.sprintf "required GitHub CLI parent is missing: %s" path)
  | Ok (Some stats) when stats.Unix.st_kind = Unix.S_DIR -> Ok ()
  | Ok (Some stats) ->
    Error
      (Printf.sprintf
         "GitHub CLI path must be a directory, not a %s: %s"
         (file_kind_to_string stats.Unix.st_kind)
         path)
;;

let ensure_child_directory ~parent ~name ~private_mode =
  match require_directory parent with
  | Error _ as error -> error
  | Ok () ->
    let path = Filename.concat parent name in
    (match lstat_opt path with
     | Error _ as error -> error
     | Ok None ->
       (try Unix.mkdir path 0o700 with
        | Unix.Unix_error (Unix.EEXIST, _, _) -> ()
        | Unix.Unix_error (error, operation, target) ->
          raise (Unix.Unix_error (error, operation, target)));
       (match require_directory path with
        | Error _ as error -> error
        | Ok () ->
          if private_mode then Unix.chmod path 0o700;
          Ok path)
     | Ok (Some stats) when stats.Unix.st_kind = Unix.S_DIR ->
       if private_mode then Unix.chmod path 0o700;
       Ok path
     | Ok (Some stats) ->
       Error
         (Printf.sprintf
            "GitHub CLI path must be a directory, not a %s: %s"
            (file_kind_to_string stats.Unix.st_kind)
            path))
;;

let inspect_config_files_in ~on_regular config_path =
  let rec inspect = function
    | [] -> Ok ()
    | filename :: rest ->
      let path = Filename.concat config_path filename in
      (match lstat_opt path with
     | Error _ as error -> error
     | Ok None -> inspect rest
     | Ok (Some stats) when stats.Unix.st_kind = Unix.S_REG ->
         (match on_regular path stats with
          | Error _ as error -> error
          | Ok () -> inspect rest)
       | Ok (Some stats) ->
         Error
           (Printf.sprintf
              "GitHub CLI credential must be a regular file, not a %s: %s"
              (file_kind_to_string stats.Unix.st_kind)
              path))
  in
  inspect [ "hosts.yml"; "config.yml" ]
;;

let secure_config_files_in config_path =
  inspect_config_files_in
    ~on_regular:(fun path _stats ->
      Unix.chmod path 0o600;
      Ok ())
    config_path
;;

let validate_config_files_in config_path =
  let expected_uid = Unix.getuid () in
  let validate_regular path stats =
    let mode = stats.Unix.st_perm land 0o777 in
    if stats.Unix.st_uid <> expected_uid
    then
      Error
        (Printf.sprintf
           "GitHub CLI credential owner is unsafe: expected uid=%d actual uid=%d path=%s"
           expected_uid
           stats.Unix.st_uid
           path)
    else if mode <> 0o600
    then
      Error
        (Printf.sprintf
           "GitHub CLI credential mode is unsafe: expected 0600 actual %04o path=%s"
           mode
           path)
    else Ok ()
  in
  inspect_config_files_in ~on_regular:validate_regular config_path
;;

let validate_existing_config_dir path =
  let expected_uid = Unix.getuid () in
  match lstat_opt path with
  | Error _ as error -> error
  | Ok None -> Error (Printf.sprintf "GitHub CLI config directory disappeared: %s" path)
  | Ok (Some stats) when stats.Unix.st_kind <> Unix.S_DIR ->
    Error
      (Printf.sprintf
         "GitHub CLI path must be a directory, not a %s: %s"
         (file_kind_to_string stats.Unix.st_kind)
         path)
  | Ok (Some stats) ->
    let mode = stats.Unix.st_perm land 0o777 in
    if stats.Unix.st_uid <> expected_uid
    then
      Error
        (Printf.sprintf
           "GitHub CLI config directory owner is unsafe: expected uid=%d actual uid=%d path=%s"
           expected_uid
           stats.Unix.st_uid
           path)
    else if mode <> 0o700
    then
      Error
        (Printf.sprintf
           "GitHub CLI config directory mode is unsafe: expected 0700 actual %04o path=%s"
           mode
           path)
    else validate_config_files_in path
;;

let ensure_config_dir ~config ~keeper_name =
  if not (Keeper_config.validate_name keeper_name)
  then Error (Printf.sprintf "invalid keeper name: %s" keeper_name)
  else begin
    let keepers_root = Workspace.keepers_runtime_dir config in
    try
      match require_directory keepers_root with
      | Error _ as error -> error
      | Ok () ->
        (match
           ensure_child_directory
             ~parent:keepers_root
             ~name:keeper_name
             ~private_mode:false
         with
         | Error _ as error -> error
         | Ok keeper_root ->
           (match
              ensure_child_directory
                ~parent:keeper_root
                ~name:"github-cli"
                ~private_mode:true
            with
            | Error _ as error -> error
            | Ok path ->
              (match secure_config_files_in path with
               | Error _ as error -> error
               | Ok () -> Ok path)))
    with
    | Unix.Unix_error (error, operation, target) ->
      Error
        (Printf.sprintf
           "cannot prepare GitHub CLI directory under %s: %s(%s): %s"
           keepers_root
           operation
           target
           (Unix.error_message error))
  end
;;

let env_key entry =
  match String.index_opt entry '=' with
  | None -> entry
  | Some index -> String.sub entry 0 index
;;

let remove_env_keys keys env =
  Array.to_list env
  |> List.filter (fun entry -> not (List.mem (env_key entry) keys))
  |> Array.of_list
;;

let overlay_config_env ~config_dir env =
  Array.append
    [| "GH_CONFIG_DIR=" ^ config_dir |]
    (remove_env_keys [ "GH_CONFIG_DIR" ] env)
;;

let projected_config_dir env =
  let prefix = "GH_CONFIG_DIR=" in
  Array.find_map
    (fun entry ->
       if String.starts_with ~prefix entry
       then
         Some
           (String.sub
              entry
              (String.length prefix)
              (String.length entry - String.length prefix))
       else None)
    env
;;

let strip_github_token_env env = remove_env_keys github_token_env_names env

let projected_token_env_names env =
  List.filter
    (fun name -> Array.exists (fun entry -> String.equal (env_key entry) name) env)
    github_token_env_names
;;

type tool_identity_state =
  | Unconfigured
  | Configured of string

type docker_tool_projection =
  { args : string list
  ; identity_state : tool_identity_state
  ; host_snapshot_dir : string
  ; revision : string
  ; cleanup : unit -> unit
  }

let unconfigured_tool_identity_revision =
  Digestif.SHA256.(digest_string "masc.github-tool-identity.unconfigured.v1" |> to_hex)
;;

let yaml_scalar_has_value value =
  let value = String.trim value in
  not
    (String.equal value ""
     || String.equal value "''"
     || String.equal value "\"\""
     || String.equal value "null"
     || String.equal value "~")
;;

(* [gh auth login --insecure-storage] writes a deterministic mapping whose
   credential authority is an [oauth_token] scalar, either directly below a
   host or below that host's [users] mapping.  Decode that closed shape instead
   of treating arbitrary non-empty bytes (notably the post-logout [{}]) as an
   identity.  Unsupported YAML constructs fail closed rather than being
   guessed into configured state.

   Returns the (host, token) pairs it decoded rather than a bare "yes". One
   scanner answers both questions asked of this file -- whether an identity is
   configured, and what the token for a given host is -- because a second
   decoder of the same bytes is a second thing to keep in step. *)
let hosts_yaml_stored_tokens content =
  let lines = String.split_on_char '\n' content in
  let meaningful =
    List.filter_map
      (fun raw_line ->
         let line = String.trim raw_line in
         if String.equal line "" || String.starts_with ~prefix:"#" line
         then None
         else Some raw_line)
      lines
  in
  match meaningful with
  | [] -> Ok []
  | [ line ] when String.equal (String.trim line) "{}" -> Ok []
  | _ ->
    let rec scan active_host found = function
      | [] -> Ok (List.rev found)
      | raw_line :: rest ->
        if String.contains raw_line '\t'
        then Error "GitHub CLI hosts.yml must not contain tab indentation"
        else
          let indentation =
            let rec count index =
              if index < String.length raw_line && raw_line.[index] = ' '
              then count (index + 1)
              else index
            in
            count 0
          in
          let line = String.sub raw_line indentation (String.length raw_line - indentation) in
          if String.equal line "" || String.starts_with ~prefix:"#" line
          then scan active_host found rest
          else
            (match String.index_opt line ':' with
             | None -> Error "GitHub CLI hosts.yml contains a non-mapping entry"
             | Some separator ->
               let key = String.sub line 0 separator |> String.trim in
               let value =
                 String.sub
                   line
                   (separator + 1)
                   (String.length line - separator - 1)
                 |> String.trim
               in
               if String.equal key ""
               then Error "GitHub CLI hosts.yml contains an empty mapping key"
               else if indentation = 0
               then
                 if not (String.equal value "")
                 then Error "GitHub CLI host entry must be a mapping"
                 else scan (Some key) found rest
               else (
                 match active_host with
                 | None ->
                   Error "GitHub CLI hosts.yml contains data outside a host mapping"
                 | Some host ->
                   if String.equal key "oauth_token" && yaml_scalar_has_value value
                   then scan active_host ((host, value) :: found) rest
                   else scan active_host found rest))
    in
    scan None [] meaningful
;;

let hosts_yaml_has_stored_token content =
  Result.map (fun pairs -> pairs <> []) (hosts_yaml_stored_tokens content)
;;

let hosts_file_has_stored_token ~config_dir hosts_path =
  match Fs_compat.load_owned_regular_file ~ownership_root:config_dir hosts_path with
  | Error error -> Error (Fs_compat.owned_regular_file_read_error_to_string error)
  | Ok None -> Ok false
  | Ok (Some content) -> hosts_yaml_has_stored_token content
;;

(* The token this Keeper's gh CLI already holds for [hostname].

   Read on demand rather than copied anywhere. gh owns hosts.yml and rewrites
   it on every login and logout; a copy kept beside it would answer with a
   credential the Keeper no longer has, and nothing in either file would say
   which one was current. Absence is an error naming the fix rather than an
   empty token, because a caller that got "" would send it and read GitHub's
   401 as the provider being down. *)
let stored_token ~base_path ~keeper_name ~hostname =
  let config_dir = config_dir_of_base_path ~base_path ~keeper_name in
  let hosts_path = Filename.concat config_dir "hosts.yml" in
  match Fs_compat.load_owned_regular_file ~ownership_root:config_dir hosts_path with
  | Error error -> Error (Fs_compat.owned_regular_file_read_error_to_string error)
  | Ok None ->
    Error
      (Printf.sprintf
         "keeper %S has no GitHub CLI identity; log it in from the GitHub tab first"
         keeper_name)
  | Ok (Some content) ->
    (match hosts_yaml_stored_tokens content with
     | Error _ as error -> error
     | Ok pairs ->
       (match List.assoc_opt hostname pairs with
        | Some token -> Ok token
        | None ->
          Error
            (Printf.sprintf
               "keeper %S has a GitHub CLI identity but none for %s"
               keeper_name
               hostname)))
;;

let inspect_optional_directory path =
  match lstat_opt path with
  | Error _ as error -> error
  | Ok None -> Ok false
  | Ok (Some stats) when stats.Unix.st_kind = Unix.S_DIR -> Ok true
  | Ok (Some stats) ->
    Error
      (Printf.sprintf
         "GitHub CLI path must be a directory, not a %s: %s"
         (file_kind_to_string stats.Unix.st_kind)
         path)
;;

let existing_config_dir ~config ~keeper_name =
  if not (Keeper_config.validate_name keeper_name)
  then Error (Printf.sprintf "invalid keeper name: %s" keeper_name)
  else begin
    let keepers_root = Workspace.keepers_runtime_dir config in
    let keeper_root = Filename.concat keepers_root keeper_name in
    let keeper_config_dir = Filename.concat keeper_root "github-cli" in
    match inspect_optional_directory keepers_root with
    | Error _ as error -> error
    | Ok false -> Ok None
    | Ok true ->
      (match inspect_optional_directory keeper_root with
       | Error _ as error -> error
       | Ok false -> Ok None
       | Ok true ->
         (match inspect_optional_directory keeper_config_dir with
          | Error _ as error -> error
          | Ok false -> Ok None
          | Ok true ->
            (match validate_existing_config_dir keeper_config_dir with
             | Error _ as error -> error
             | Ok () ->
               let hosts_path = Filename.concat keeper_config_dir "hosts.yml" in
               (match lstat_opt hosts_path with
                | Error _ as error -> error
                | Ok None -> Ok None
                | Ok (Some stats) when stats.Unix.st_kind = Unix.S_REG ->
                  (match
                     hosts_file_has_stored_token
                       ~config_dir:keeper_config_dir
                       hosts_path
                   with
                   | Error _ as error -> error
                   | Ok true -> Ok (Some keeper_config_dir)
                   | Ok false -> Ok None)
                | Ok (Some stats) ->
                  Error
                    (Printf.sprintf
                       "GitHub CLI credential must be a regular file, not a %s: %s"
                       (file_kind_to_string stats.Unix.st_kind)
                       hosts_path)))))
  end
;;

let load_optional_config_file config_dir filename =
  let path = Filename.concat config_dir filename in
  match Fs_compat.load_owned_regular_file ~ownership_root:config_dir path with
  | Error error -> Error (Fs_compat.owned_regular_file_read_error_to_string error)
  | Ok content -> Ok content
;;

let configured_tool_identity_revision config_dir =
  match load_optional_config_file config_dir "hosts.yml" with
  | Error _ as error -> error
  | Ok None -> Error "configured GitHub CLI identity has no hosts.yml"
  | Ok (Some hosts) ->
    (match load_optional_config_file config_dir "config.yml" with
     | Error _ as error -> error
     | Ok config ->
       let material =
         Yojson.Safe.to_string
           (`Assoc
              [ "schema", `String "masc.github-tool-identity-revision.v1"
              ; "hosts.yml", `String hosts
              ; ( "config.yml"
                , match config with
                  | None -> `Null
                  | Some value -> `String value )
              ])
       in
       Ok Digestif.SHA256.(digest_string material |> to_hex))
;;

let current_tool_identity_revision ~config ~keeper_name =
  match existing_config_dir ~config ~keeper_name with
  | Error _ as error -> error
  | Ok None -> Ok unconfigured_tool_identity_revision
  | Ok (Some config_dir) -> configured_tool_identity_revision config_dir
;;

let snapshot_cleanup snapshot =
  let descriptor = Unix.openfile snapshot [ Unix.O_RDONLY ] 0 in
  Unix.set_close_on_exec descriptor;
  let created = Unix.fstat descriptor in
  let claimed = Atomic.make false in
  fun () ->
    if Atomic.compare_and_set claimed false true
    then
      Fun.protect
        ~finally:(fun () -> Unix.close descriptor)
        (fun () ->
           match lstat_opt snapshot with
           | Ok None -> ()
           | Ok (Some current)
             when current.Unix.st_kind = Unix.S_DIR
                  && current.Unix.st_dev = created.Unix.st_dev
                  && current.Unix.st_ino = created.Unix.st_ino ->
             (* Change permissions through the descriptor captured before the
                child ran. A pathname chmod could follow a replacement
                symlink between validation and cleanup. *)
             Unix.fchmod descriptor 0o700;
             Fs_compat.remove_tree snapshot
           | Ok (Some _) | Error _ ->
             (* The non-following tree remover unlinks a replacement entry
                directly and never traverses a replacement symlink. *)
             Fs_compat.remove_tree snapshot)
;;

let copy_local_tool_config_snapshot existing =
  let snapshot = Filename.temp_dir "masc-gh-tool-" "" in
  Unix.chmod snapshot 0o700;
  let cleanup = snapshot_cleanup snapshot in
  let copy_file filename =
    let source = Filename.concat existing filename in
    let target = Filename.concat snapshot filename in
    match Fs_compat.load_owned_regular_file ~ownership_root:existing source with
    | Error error ->
      Error (Fs_compat.owned_regular_file_read_error_to_string error)
    | Ok None -> Ok ()
    | Ok (Some content) ->
      (match Fs_compat.save_file_atomic target content with
       | Error _ as error -> error
       | Ok () ->
         Unix.chmod target 0o400;
         Ok ())
  in
  match copy_file "hosts.yml" with
  | Error error ->
    cleanup ();
    Error error
  | Ok () ->
    (match copy_file "config.yml" with
     | Error error ->
       cleanup ();
       Error error
     | Ok () ->
       Unix.chmod snapshot 0o500;
       Ok (snapshot, cleanup))
;;

let empty_local_tool_config_snapshot () =
  let snapshot = Filename.temp_dir "masc-gh-tool-empty-" "" in
  let cleanup = snapshot_cleanup snapshot in
  Unix.chmod snapshot 0o500;
  snapshot, cleanup
;;

let git_credential_config_file_name = "gitconfig"

(* The hostnames this identity is logged into. hosts.yml is gh-owned and
   stable in shape: a top-level key is a line that starts at column zero and
   ends with ':'. Nothing else in the file has that shape. *)
let hostnames_of_hosts_yml contents =
  String.split_on_char '\n' contents
  |> List.filter_map (fun line ->
    let len = String.length line in
    if len < 2 || line.[0] = ' ' || line.[0] = '\t' || line.[len - 1] <> ':'
    then None
    else (
      let host = String.trim (String.sub line 0 (len - 1)) in
      if String.equal host "" || String.contains host ' ' || String.contains host '"'
      then None
      else Some host))
;;

(* git never consults gh's hosts.yml on its own: an https push without a
   credential helper prompts for a username, and a sandbox has no terminal
   to answer, so a projected token sits unused ("could not read Username",
   measured on a replayed push with a valid token — task-847). The identity
   snapshot therefore carries the same wiring [gh auth setup-git] writes,
   derived from the hosts this identity actually holds, and only when it
   holds any. The file is derived state, deliberately outside the identity
   revision digest: the digest answers "did the login change", and this file
   is a pure function of it.

   [dir_mode_after] is the directory mode restored after the write: a locked
   0500 for turn snapshots, 0700 for the stable config directory
   ([validate_existing_config_dir] rejects anything else). *)
let write_git_credential_config ~dir_mode_after ~snapshot =
  match
    Fs_compat.load_owned_regular_file
      ~ownership_root:snapshot
      (Filename.concat snapshot "hosts.yml")
  with
  | Error error -> Error (Fs_compat.owned_regular_file_read_error_to_string error)
  | Ok None -> Ok false
  | Ok (Some contents) ->
    (match hostnames_of_hosts_yml contents with
     | [] -> Ok false
     | hosts ->
       let stanza host =
         Printf.sprintf
           "[credential \"https://%s\"]\n\thelper = \n\thelper = !gh auth git-credential\n"
           host
       in
       (* gh's own setup-git pairs github.com with its gist host. *)
       let hosts =
         if List.exists (String.equal "github.com") hosts
            && not (List.exists (String.equal "gist.github.com") hosts)
         then hosts @ [ "gist.github.com" ]
         else hosts
       in
       let content = String.concat "" (List.map stanza hosts) in
       let target = Filename.concat snapshot git_credential_config_file_name in
       Unix.chmod snapshot 0o700;
       let result =
         match Fs_compat.save_file_atomic target content with
         | Error _ as error -> error
         | Ok () ->
           Unix.chmod target 0o400;
           Ok true
       in
       Unix.chmod snapshot dir_mode_after;
       result)
;;

let runtime_env_for_tool ~config ~keeper_name env =
  match existing_config_dir ~config ~keeper_name with
  | Error _ as error -> error
  | Ok None ->
    let snapshot, cleanup = empty_local_tool_config_snapshot () in
    Ok (overlay_config_env ~config_dir:snapshot env, Unconfigured, cleanup)
  | Ok (Some path) ->
    (match copy_local_tool_config_snapshot path with
     | Error _ as error -> error
     | Ok (snapshot, cleanup) ->
       Ok (overlay_config_env ~config_dir:snapshot env, Configured path, cleanup))
;;

let docker_args ~config ~keeper_name ~container_masc_dir =
  match ensure_config_dir ~config ~keeper_name with
  | Error _ as error -> error
  | Ok host_dir ->
    let container_dir = container_config_dir ~container_masc_dir ~keeper_name in
    Ok
      [ "--env"
      ; "GH_CONFIG_DIR=" ^ container_dir
      ; "-v"
      ; host_dir ^ ":" ^ container_dir ^ ":ro"
      ]
;;

(* Keeper-lifetime containers cannot mount a per-turn snapshot: turn cleanup
   deletes the snapshot directory while the container keeps running, and the
   bind mount would read a vanished path. They mount the stable config
   directory itself — read-only, so in-container writes stay impossible, but
   a host login reaches a running container through the mount. The git wiring
   is the same pure function of hosts.yml the snapshot lane writes; the
   stable dir's validator inspects only hosts.yml and config.yml, so the
   added gitconfig does not break it. GIT_CONFIG_GLOBAL always points at
   that file: a missing file reads as an empty config to git, so the env
   stays correct across identity changes without recreating the container.

   An unconfigured keeper (no stable dir yet) gets no identity args at all
   rather than a provisioned empty one: starting a container must not create
   directories, and a gh with no GH_CONFIG_DIR is unconfigured either way.
   The cost is explicit — a container created before the first login stays
   without the mount until the keeper's teardown recreates it. *)
let docker_args_persistent ~config ~keeper_name ~container_masc_dir =
  match existing_config_dir ~config ~keeper_name with
  | Error _ as error -> error
  | Ok None -> Ok []
  | Ok (Some host_dir) ->
    (match write_git_credential_config ~dir_mode_after:0o700 ~snapshot:host_dir with
     | Error _ as error -> error
     | Ok _has_git_wiring ->
       let container_dir = container_config_dir ~container_masc_dir ~keeper_name in
       Ok
         [ "--env"
         ; "GH_CONFIG_DIR=" ^ container_dir
         ; "-v"
         ; host_dir ^ ":" ^ container_dir ^ ":ro"
         ; "--env"
         ; "GIT_CONFIG_GLOBAL="
           ^ Filename.concat container_dir git_credential_config_file_name
         ])
;;

(* Refresh of the derived gitconfig for the persistent mount, called when a
   container is adopted: hosts written by logins that happened while no turn
   was watching get their credential wiring without a container restart. *)
let refresh_git_credential_config ~config ~keeper_name =
  match existing_config_dir ~config ~keeper_name with
  | Error _ as error -> error
  | Ok None -> Ok false
  | Ok Some dir -> write_git_credential_config ~dir_mode_after:0o700 ~snapshot:dir
;;

let docker_args_for_tool ~config ~keeper_name ~container_masc_dir =
  match existing_config_dir ~config ~keeper_name with
  | Error _ as error -> error
  | Ok None ->
    let snapshot, cleanup = empty_local_tool_config_snapshot () in
    let container_dir = container_config_dir ~container_masc_dir ~keeper_name in
    Ok
      { args =
          [ "--env"
          ; "GH_CONFIG_DIR=" ^ container_dir
          ; "-v"
          ; snapshot ^ ":" ^ container_dir ^ ":ro"
          ]
      ; identity_state = Unconfigured
      ; host_snapshot_dir = snapshot
      ; revision = unconfigured_tool_identity_revision
      ; cleanup
      }
  | Ok (Some host_dir) ->
    (match copy_local_tool_config_snapshot host_dir with
     | Error _ as error -> error
     | Ok (snapshot, cleanup) ->
       (match configured_tool_identity_revision snapshot with
        | Error error ->
          cleanup ();
          Error error
        | Ok revision ->
          (match write_git_credential_config ~dir_mode_after:0o500 ~snapshot with
           | Error error ->
             cleanup ();
             Error error
           | Ok has_git_wiring ->
             let container_dir =
               container_config_dir ~container_masc_dir ~keeper_name
             in
             let git_wiring_args =
               if has_git_wiring
               then
                 [ "--env"
                 ; "GIT_CONFIG_GLOBAL="
                   ^ Filename.concat container_dir git_credential_config_file_name
                 ]
               else []
             in
             Ok
               { args =
                   [ "--env"
                   ; "GH_CONFIG_DIR=" ^ container_dir
                   ; "-v"
                   ; snapshot ^ ":" ^ container_dir ^ ":ro"
                   ]
                   @ git_wiring_args
               ; identity_state = Configured host_dir
               ; host_snapshot_dir = snapshot
               ; revision
               ; cleanup
               })))
;;

let login_argv ~hostname =
  [ "gh"
  ; "auth"
  ; "login"
  ; "--hostname"
  ; hostname
  ; "--git-protocol"
  ; "https"
  ; "--skip-ssh-key"
  ; "--web"
  ; "--insecure-storage"
  ]
;;

let logout_argv ~hostname = [ "gh"; "auth"; "logout"; "--hostname"; hostname ]

let projected_base_env ~base_path ~keeper_name =
  match
    Keeper_secret_projection.local_env_for_keeper
      ~host_env:(Unix.environment ())
      ~base_path
      ~keeper_name
      ()
  with
  | Error _ as error -> error
  | Ok None ->
    Error
      "keeper secret projection returned no environment; refusing host-environment fallback"
  | Ok (Some env) -> Ok env
;;

let host_process_env_names =
  [ "PATH"
  ; "HOME"
  ; "TMPDIR"
  ; "LANG"
  ; "LC_ALL"
  ; "LC_CTYPE"
  ; "SSL_CERT_FILE"
  ; "SSL_CERT_DIR"
  ; "HTTP_PROXY"
  ; "HTTPS_PROXY"
  ; "NO_PROXY"
  ; "http_proxy"
  ; "https_proxy"
  ; "no_proxy"
  ]
;;

let entries_for_names names env =
  Array.to_list env
  |> List.filter (fun entry -> List.mem (env_key entry) names)
  |> Array.of_list
;;

let minimal_host_process_env () =
  Unix.environment ()
  |> remove_env_keys ("GH_CONFIG_DIR" :: github_token_env_names)
  |> entries_for_names host_process_env_names
;;

let github_probe_env projected_env =
  Array.append
    (entries_for_names github_token_env_names projected_env)
    (minimal_host_process_env ())
;;

let login_env ~config ~keeper_name =
  match ensure_config_dir ~config ~keeper_name with
  | Error _ as error -> error
  | Ok keeper_config_dir ->
    Ok (overlay_config_env ~config_dir:keeper_config_dir (minimal_host_process_env ()))
;;

let process_exit_text = function
  | Unix.WEXITED code -> Printf.sprintf "exit %d" code
  | Unix.WSIGNALED signal -> Printf.sprintf "signal %d" signal
  | Unix.WSTOPPED signal -> Printf.sprintf "stopped by signal %d" signal
;;

let run_capture ~env = function
  | [] -> Unix.WEXITED 127, "", "GitHub CLI argv must not be empty"
  | argv ->
    Process_eio.run_argv_with_status_split
      ~timeout_sec:15.0
      ~env
      argv
;;

let auth_result_of_command ~redact ~env ~hostname =
  let status, stdout, stderr =
    run_capture
      ~env
      [ "gh"; "api"; "--hostname"; hostname; "user"; "--jq"; ".login" ]
  in
  let login = String.trim stdout in
  match status with
  | Unix.WEXITED 0 when not (String.equal login "") ->
    { authenticated = true; login = Some login; error = None }
  | _ ->
    let detail = String.trim (redact stderr) in
    let detail = if String.equal detail "" then process_exit_text status else detail in
    { authenticated = false; login = None; error = Some detail }
;;

let observe ~config ~keeper_name ~hostname =
  let base_path = config.Workspace.base_path in
  let hostname = String.trim hostname in
  if String.equal hostname "" then Error "GitHub hostname must not be empty"
  else
    match projected_base_env ~base_path ~keeper_name with
    | Error _ as error -> error
    | Ok base_env ->
      let redaction = Keeper_secret_redaction.snapshot ~base_path ~keeper_name in
      let redact = Keeper_secret_redaction.redact_text redaction in
      let token_env_names = projected_token_env_names base_env in
      (match existing_config_dir ~config ~keeper_name with
       | Error _ as error -> error
       | Ok existing ->
         let unconfigured =
           { authenticated = false
           ; login = None
           ; error = Some "Keeper GitHub CLI identity is not configured"
           }
         in
         let host_env = minimal_host_process_env () in
         let effective_host_env = github_probe_env base_env in
         let probe_with_ephemeral_config env =
           let probe_dir = Filename.temp_dir "masc-gh-observe-" "" in
           Unix.chmod probe_dir 0o700;
           Fun.protect
             ~finally:(fun () -> Fs_compat.remove_tree probe_dir)
             (fun () ->
                auth_result_of_command
                  ~redact
                  ~env:(overlay_config_env ~config_dir:probe_dir env)
                  ~hostname)
         in
         let stored, effective =
           match existing with
           | Some path ->
             let stored_env = overlay_config_env ~config_dir:path host_env in
             let effective_env = overlay_config_env ~config_dir:path effective_host_env in
             ( auth_result_of_command
                 ~redact
                 ~env:stored_env
                 ~hostname
             , auth_result_of_command ~redact ~env:effective_env ~hostname )
           | None ->
             let effective =
               match token_env_names with
               | [] -> unconfigured
               | _ :: _ -> probe_with_ephemeral_config effective_host_env
             in
             unconfigured, effective
         in
         Ok
           { keeper = keeper_name
           ; hostname
           ; config_dir = config_dir ~config ~keeper_name
           ; projected_token_env_names = token_env_names
           ; stored
           ; effective
           ; effective_probe_scope = `Host_process_credential_only
           ; checked_at_unix = Time_compat.now ()
           })
;;

let auth_result_to_yojson result =
  `Assoc
    [ "authenticated", `Bool result.authenticated
    ; "login", (match result.login with Some value -> `String value | None -> `Null)
    ; "error", (match result.error with Some value -> `String value | None -> `Null)
    ]
;;

let observation_to_yojson observation =
  `Assoc
    [ "ok", `Bool true
    ; "keeper", `String observation.keeper
    ; "hostname", `String observation.hostname
    ; "config_dir", `String observation.config_dir
    ; ( "projected_token_env_names"
      , `List (List.map (fun value -> `String value) observation.projected_token_env_names) )
    ; "stored", auth_result_to_yojson observation.stored
    ; "effective", auth_result_to_yojson observation.effective
    ; "effective_probe_scope", `String "host_process_credential_only"
    ; "checked_at_unix", `Float observation.checked_at_unix
    ]
;;

let secure_config_files ~config ~keeper_name =
  let root = config_dir ~config ~keeper_name in
  try
    match require_directory root with
    | Error _ as error -> error
    | Ok () ->
      Unix.chmod root 0o700;
      secure_config_files_in root
  with
  | Unix.Unix_error (error, operation, target) ->
    Error
      (Printf.sprintf
         "cannot secure GitHub CLI path %s: %s(%s): %s"
         root
         operation
         target
         (Unix.error_message error))
;;

let stream_login ~config ~keeper_name ~hostname ~env ~is_closed ~send_event =
  let base_path = config.Workspace.base_path in
  let send event json =
    if is_closed ()
    then raise (Eio.Cancel.Cancelled (Failure "GitHub login response closed"))
    else
      try send_event event json with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> raise (Eio.Cancel.Cancelled exn)
  in
  match Eio_context.get_clock_opt () with
  | None -> Error "GitHub login streaming requires the server Eio clock"
  | Some clock ->
    let redaction = Keeper_secret_redaction.snapshot ~base_path ~keeper_name in
    let stdout_redaction = Keeper_secret_redaction.create_stream_state redaction in
    let stderr_redaction = Keeper_secret_redaction.create_stream_state redaction in
    let send_redacted_output stream state chunk =
      let text = Keeper_secret_redaction.redact_stream_chunk state chunk in
      if not (String.equal text "")
      then send "output" (`Assoc [ "stream", `String stream; "text", `String text ])
    in
    let finish_redacted_output stream state =
      let text = Keeper_secret_redaction.redact_stream_finish state in
      if not (String.equal text "")
      then send "output" (`Assoc [ "stream", `String stream; "text", `String text ])
    in
    let run_process () =
      let finished = Atomic.make false in
      let process_result = ref None in
      Eio.Cancel.sub (fun cancellation ->
        Eio.Fiber.both
          (fun () ->
             Fun.protect
               ~finally:(fun () -> Atomic.set finished true)
               (fun () ->
                  process_result :=
                    Some
                      (Process_eio.run_argv_with_status_split_streaming
                         ~timeout_sec:600.0
                         ~env
                         ~on_stdout_chunk:
                           (send_redacted_output "stdout" stdout_redaction)
                         ~on_stderr_chunk:
                           (send_redacted_output "stderr" stderr_redaction)
                         (login_argv ~hostname))))
          (fun () ->
             while (not (Atomic.get finished)) && not (is_closed ()) do
               Eio.Time.sleep clock 0.1
             done;
             if is_closed ()
             then
               Eio.Cancel.cancel
                 cancellation
                 (Failure "GitHub login response closed")));
      match !process_result with
      | Some result -> result
      | None -> failwith "GitHub login process completed without a result"
    in
    (try
       let status, _, stderr = run_process () in
       finish_redacted_output "stdout" stdout_redaction;
       finish_redacted_output "stderr" stderr_redaction;
       let stderr = Keeper_secret_redaction.redact_text redaction stderr in
       (match status with
        | Unix.WEXITED 0 ->
          (match secure_config_files ~config ~keeper_name with
           | Error message -> send "error" (`Assoc [ "message", `String message ])
           | Ok () ->
             (match observe ~config ~keeper_name ~hostname with
              | Ok observation ->
                send
                  "complete"
                  (`Assoc [ "observation", observation_to_yojson observation ])
              | Error message ->
                send "error" (`Assoc [ "message", `String message ])))
        | failed ->
          let detail = String.trim stderr in
          let detail =
            if String.equal detail "" then process_exit_text failed else detail
          in
          send "error" (`Assoc [ "message", `String detail ]));
       Ok ()
     with
     | Eio.Cancel.Cancelled _ when is_closed () -> Ok ()
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | exn -> Error (Printexc.to_string exn))
;;

let print_observation ~config ~keeper_name ~hostname =
  match observe ~config ~keeper_name ~hostname with
  | Error message ->
    prerr_endline message;
    false
  | Ok observation ->
    observation_to_yojson observation |> Yojson.Safe.pretty_to_string |> print_endline;
    true
;;

let run_inherited ~timeout_sec ~env = function
  | [] -> Unix.WEXITED 127
  | command :: _ as argv ->
    (try
       let process =
         Unix.create_process_env
           command
           (Array.of_list argv)
           env
           Unix.stdin
           Unix.stdout
           Unix.stderr
       in
       (* NDT-OK: wall-clock deadline bounds the subprocess; on expiry the
          child is SIGKILLed and reaped, so non-determinism stays at the process boundary. *)
       let started_at = Unix.gettimeofday () in
       let deadline = started_at +. timeout_sec in
       let rec wait () =
         try
           match Unix.waitpid [ Unix.WNOHANG ] process with
           | 0, _ ->
             (* NDT-OK: wall-clock deadline; on expiry the child is SIGKILLed
                and reaped, keeping non-determinism at the process boundary. *)
             if Unix.gettimeofday () >= deadline then begin
               (try Unix.kill process Sys.sigkill with Unix.Unix_error _ -> ());
               let rec reap () =
                 try snd (Unix.waitpid [] process) with
                 | Unix.Unix_error (Unix.EINTR, _, _) -> reap ()
               in
               (* fire-and-forget: reap the SIGKILLed child to avoid a zombie *)
               ignore (reap ());
               Unix.WEXITED 124
             end else begin
               (* fire-and-forget: poll sleep; EINTR is handled by the outer wait loop *)
               ignore (Unix.select [] [] [] 0.05);
               wait ()
             end
           | _, status -> status
         with
         | Unix.Unix_error (Unix.EINTR, _, _) -> wait ()
       in
       wait ()
     with
     | Unix.Unix_error (error, operation, target) ->
       prerr_endline
         (Printf.sprintf
            "cannot run GitHub CLI: %s(%s): %s"
            operation
            target
            (Unix.error_message error));
       Unix.WEXITED 127)
;;

let run_cli_login ~config ~keeper_name ~hostname =
  match login_env ~config ~keeper_name with
  | Error message ->
    prerr_endline message;
    1
  | Ok env ->
    let status = run_inherited ~timeout_sec:600.0 ~env (login_argv ~hostname) in
    let secured =
      match status with
      | Unix.WEXITED 0 ->
        (match secure_config_files ~config ~keeper_name with
         | Ok () -> true
         | Error message ->
           prerr_endline message;
           false)
      | _ ->
        prerr_endline ("gh auth login failed: " ^ process_exit_text status);
        false
    in
    let observed = print_observation ~config ~keeper_name ~hostname in
    if secured && observed then 0 else 1
;;

let run_cli_status ~config ~keeper_name ~hostname =
  if print_observation ~config ~keeper_name ~hostname then 0 else 1
;;

let run_cli_logout ~config ~keeper_name ~hostname =
  match login_env ~config ~keeper_name with
  | Error message ->
    prerr_endline message;
    1
  | Ok env ->
    let status = run_inherited ~timeout_sec:600.0 ~env (logout_argv ~hostname) in
    let logged_out =
      match status with
      | Unix.WEXITED 0 -> true
      | _ ->
        prerr_endline ("gh auth logout failed: " ^ process_exit_text status);
        false
    in
    let observed = print_observation ~config ~keeper_name ~hostname in
    if logged_out && observed then 0 else 1
;;
