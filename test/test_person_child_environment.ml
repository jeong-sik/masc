(* The children an official client starts on the account home of a person
   get no token of the operator (RFC a-persons-keeper-runs-on-the-engine,
   S1, section 5). The engine of a multi-account installation does not
   export the admin token and the internal Keeper token
   (Server_runtime_bootstrap, Server_runtime_startup_credentials), but its
   process keeps them when the shell that started it set them.

   Each child of Claude Code and Codex for a person takes the environment of
   an account that Runtime_official_account captured: [capture] on a login,
   as the login environment of each client does, and [capture_on_key] on a
   key of Claude Code (a key account of Codex is refused). Muse Code filters
   its login child by its own list. The cases call these four builders. The
   capture of Codex also passes the names the config.toml of its home lists;
   a turn or a check refuses a home that lists any
   (Runtime_account_access, Home_asks_for_environment), and the login home
   of a person is new and lists none, as the home of each case is.

   The process of the case holds a made-up value under both names. No child
   gets either name, and every child gets the PATH value of the process, so
   the absence is the filter's and not an empty environment. *)

let operator_tokens = [ Env_config_core.admin_token_env_key; Auth.internal_keeper_token_env_key ]
let inherited_name = "PATH"
let inherited_value = "/made-up/bin"

let rec remove_tree path =
  match Unix.lstat path with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    Unix.chmod path 0o700;
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  | { Unix.st_kind = Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK; _ }
    -> Sys.remove path
;;

(* The account home of a person, in a process that holds the tokens of the
   operator. *)
let on_a_person_home run =
  List.iter (fun name -> Unix.putenv name ("made-up-value-of-" ^ name)) operator_tokens;
  Unix.putenv inherited_name inherited_value;
  let created = Filename.temp_dir ~perms:0o700 "person-child-environment-" "" in
  Fun.protect ~finally:(fun () -> remove_tree created) (fun () -> run (Unix.realpath created))
;;

let name_of entry =
  match String.index_opt entry '=' with
  | Some index -> String.sub entry 0 index
  | None -> Alcotest.failf "an entry without a name"
;;

let no_operator_token label environment =
  let entries = Array.to_list environment in
  let names = List.map name_of entries in
  List.iter
    (fun token -> Alcotest.(check bool) (label ^ ": no " ^ token) false (List.mem token names))
    operator_tokens;
  Alcotest.(check bool)
    (label ^ ": the " ^ inherited_name ^ " of the process")
    true
    (List.mem (inherited_name ^ "=" ^ inherited_value) entries)
;;

let test_claude_code () =
  on_a_person_home (fun account_home ->
    match Runtime_claude_code.login_environment ~account_home with
    | Ok environment -> no_operator_token "Claude Code" environment
    | Error error -> Alcotest.failf "no environment: %s" (Runtime_claude_code.error_to_string error))
;;

(* A key account of Claude Code builds the environment of its child apart
   from [capture]. The key is made-up, in a private file of a private folder
   outside the home, as a key file is (Runtime_api_key_file). *)
let test_claude_code_on_a_key () =
  on_a_person_home (fun account_home ->
    let key_folder = Filename.temp_dir ~perms:0o700 "person-child-key-" "" in
    Fun.protect ~finally:(fun () -> remove_tree key_folder) (fun () ->
      let key_file = Filename.concat (Unix.realpath key_folder) "made-up-key" in
      Out_channel.with_open_gen [ Open_wronly; Open_creat; Open_excl ] 0o600 key_file (fun channel ->
        Out_channel.output_string channel "made-up-key-of-a-person");
      (* The mode of the open is narrowed by the umask of the process. *)
      Unix.chmod key_file 0o600;
      match Runtime_official_account.capture_on_key ~declaration:(Some account_home) ~key_file with
      | Ok account -> no_operator_token "Claude Code on a key" (Runtime_official_account.environment account)
      | Error (Runtime_official_account.Key_not_read error) ->
        Alcotest.failf "the key was not read: %s" (Runtime_api_key_file.read_error_to_string error)
      | Error (Runtime_official_account.Key_not_captured detail) ->
        Alcotest.failf "no environment: %s" detail))
;;

let test_codex () =
  on_a_person_home (fun account_home ->
    match Runtime_codex_app_server.login_environment ~account_home with
    | Ok environment -> no_operator_token "Codex" environment
    | Error error -> Alcotest.failf "no environment: %s" (Runtime_codex_app_server.error_to_string error))
;;

let test_muse_code () =
  on_a_person_home (fun account_home ->
    no_operator_token "Muse Code" (Runtime_muse_serve.login_environment ~account_home))
;;

let () =
  Alcotest.run
    "person_child_environment"
    [ ( "the child of an official client on the home of a person"
      , [ Alcotest.test_case "Claude Code gets no token of the operator" `Quick test_claude_code
        ; Alcotest.test_case
            "Claude Code on an API key gets no token of the operator"
            `Quick
            test_claude_code_on_a_key
        ; Alcotest.test_case "Codex gets no token of the operator" `Quick test_codex
        ; Alcotest.test_case "Muse Code gets no token of the operator" `Quick test_muse_code
        ] )
    ]
;;
