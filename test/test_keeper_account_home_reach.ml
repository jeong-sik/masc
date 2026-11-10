(* A Keeper lane cannot reach the account homes of the people of a
   multi-account process (multi-account plan D3c-1, design 11.1). The homes
   sit under [<base>/.masc/accounts/], each with the login credentials of its
   person. The host process of an official CLI is closed by the native rule
   (D3c-2); these are the other ways a Keeper reaches the host:

   - a Docker container mounts its playground, the configuration and the
     Board, task and goal stores;
   - an Apple guest mounts the configuration, its GitHub identity and the
     shim, and publishes the socket of its agent;
   - the MASC Read tool reads inside the sandbox roots of the Keeper.

   No mount source and no published socket is inside the accounts directory
   or holds it. Read refuses the path of a credential, a parent escape toward
   it and a symlink the Keeper made to it in its playground, and it still
   reads a file of the Keeper's own. *)

module Workspace = Masc.Workspace
module Setup = Masc.Keeper_sandbox_runtime_setup
module Keeper_sandbox = Masc.Keeper_sandbox
module Record = Masc.Keeper_turn_sandbox_runtime_record
module Start = Masc.Keeper_turn_sandbox_runtime_start_failure
module Plan = Masc.Keeper_microvm_boot_plan
module Identity = Masc.Keeper_microvm_github_identity
module Backend = Masc.Keeper_microvm_backend
module Shared = Masc.Keeper_tool_shared_runtime
module Path = Masc.Keeper_alerting_path
module Size = Keeper_microvm_guest_size
module Profile = Keeper_types_profile_sandbox

let value = function
  | Ok value -> value
  | Error detail -> Alcotest.fail detail
;;

let rec remove_tree path =
  match Unix.lstat path with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  | { Unix.st_kind = Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK
    ; _
    } -> Sys.remove path
;;

let rec ensure_dir path =
  if not (Sys.file_exists path)
  then (
    ensure_dir (Filename.dirname path);
    Unix.mkdir path 0o700)
;;

let write_file path content =
  ensure_dir (Filename.dirname path);
  Out_channel.with_open_bin path (fun out -> output_string out content)
;;

let components path =
  String.split_on_char '/' path |> List.filter (fun part -> part <> "" && part <> ".")
;;

(* Whether [path] is [root] or lies under it, compared by components. *)
let rec under ~root path =
  match root, path with
  | [], _ -> true
  | top :: root, next :: path -> String.equal top next && under ~root path
  | _ :: _, [] -> false
;;

(* A source reaches the homes when it lies inside the accounts directory, or
   holds it, as a mount of the whole [.masc] would. *)
let reaches ~accounts source =
  let accounts = components accounts
  and source = components source in
  under ~root:accounts source || under ~root:source accounts
;;

(* The credential of another person: Bob's Claude Code login. *)
let bob_home = [ "people-bob"; "official-clients"; "claude"; "account-bob" ]
let bob_credential ~accounts = List.fold_left Filename.concat accounts (bob_home @ [ ".credentials.json" ])

let with_base f =
  let base_path = Unix.realpath (Filename.temp_dir "keeper-account-home-reach-" "") in
  Fun.protect
    ~finally:(fun () -> remove_tree base_path)
    (fun () ->
      let accounts =
        Filename.concat
          (Common.masc_dir_from_base_path ~base_path)
          Runtime_account_home_layout.accounts_dir
      in
      write_file (bob_credential ~accounts) "bob's login";
      ensure_dir (Setup.host_masc_config_dir ~base_path);
      f ~base_path ~accounts)
;;

let keeper_meta profile name =
  let meta =
    value
      (Masc_test_deps.meta_of_json_fixture
         (`Assoc [ "name", `String name; "trace_id", `String ("trace-" ^ name) ]))
  in
  { meta with sandbox_profile = profile }
;;

let relative ~base_path path =
  if String.starts_with ~prefix:base_path path
  then "<base>" ^ String.sub path (String.length base_path) (String.length path - String.length base_path)
  else path
;;

let sources_stay_out ~base_path ~accounts sources =
  List.iter
    (fun (role, source) ->
      Alcotest.(check bool)
        (Printf.sprintf "%s %s stays out of the account homes" role (relative ~base_path source))
        false
        (reaches ~accounts source))
    sources
;;

let source_of_spec spec =
  match String.split_on_char ':' spec with
  | source :: _ :: _ -> source
  | [ _ ] | [] -> Alcotest.failf "a mount has no destination: %s" spec
;;

let test_docker_mounts () =
  with_base
  @@ fun ~base_path ~accounts ->
  (* Every store is there, so every store is mounted. *)
  List.iter
    (fun (_warrant, kind, rel_path) ->
      let path = Filename.concat (Common.masc_dir_from_base_path ~base_path) rel_path in
      match kind with
      | Setup.Workspace_state_dir -> ensure_dir path
      | Setup.Workspace_state_file -> write_file path "")
    Setup.docker_workspace_state_mounts;
  let config = Workspace.default_config base_path in
  let meta = keeper_meta Profile.Docker "keeper-alice" in
  let container_root = Keeper_sandbox.container_root meta.name in
  let stores = Setup.docker_workspace_state_mount_specs ~base_path ~container_root in
  Alcotest.(check int)
    "every store is mounted"
    (List.length Setup.docker_workspace_state_mounts)
    (List.length stores);
  let configuration =
    match Setup.config_mount ~base_path ~container_root with
    | Some (source, (_ : string)) -> source
    | None -> Alcotest.fail "the configuration is not mounted"
  in
  sources_stay_out
    ~base_path
    ~accounts
    (("the playground", Keeper_sandbox.host_root_abs_of_meta ~config meta)
     :: ("the configuration", configuration)
     :: List.map (fun spec -> "the store", source_of_spec spec) stores)
;;

let test_apple_guest_mounts () =
  with_base
  @@ fun ~base_path ~accounts ->
  let config = Workspace.default_config base_path in
  let meta = keeper_meta Profile.Micro_vm "keeper-alice" in
  let runtime = Record.create ~config ~meta ~image:(Ok "fixture:image") () in
  let identity_host_dir =
    Identity.host_path
      ~base_path
      ~keeper_name:meta.name
      ~backend:Backend.Apple_container
      ~network_mode:Profile.Network_none
  in
  let guest_size =
    { Size.memory = value (Size.memory_of_string "2g"); cpus = value (Size.cpus_of_int 4) }
  in
  match
    Start.requested_apple_plan
      runtime
      ~image:"fixture:image"
      ~guest_size
      ~identity_host_dir
      ~environment:[]
      ~config_mount:(Setup.config_mount ~base_path ~container_root:runtime.Record.container_root)
      ~stable_labels:[]
  with
  | Error failure -> Alcotest.fail (Start.microvm_start_failure_message failure)
  | Ok (plan : Plan.t) ->
    let mounted =
      List.filter_map
        (function
          | Plan.Host_dir { source; destination = _; read_only = _ } -> Some ("the directory", source)
          | Plan.Tmpfs { destination = _ } | Plan.Named_volume { name = _; destination = _ } -> None)
        plan.mounts
    in
    Alcotest.(check int)
      "the configuration, the identity and the shim are mounted"
      3
      (List.length mounted);
    sources_stay_out
      ~base_path
      ~accounts
      (mounted
       @ List.map
           (fun (socket : Plan.published_socket) -> "the agent socket", socket.host_path)
           plan.published_sockets)
;;

let test_read () =
  with_base
  @@ fun ~base_path ~accounts ->
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let config = Workspace.default_config base_path in
  let meta = keeper_meta Profile.Docker "keeper-alice" in
  let playground = Keeper_sandbox.host_root_abs_of_meta ~config meta in
  write_file (Filename.concat playground "notes.txt") "her notes";
  let credential = bob_credential ~accounts in
  Unix.symlink (Filename.dirname credential) (Filename.concat playground "bob-home");
  let read raw_path = Shared.resolve_keeper_read_path ~config ~meta ~raw_path in
  (match read "notes.txt" with
   | Ok (_ : string) -> ()
   | Error refusal -> Alcotest.failf "her own file was refused: %s" refusal.Path.message);
  List.iter
    (fun (label, raw_path) ->
      match read raw_path with
      | Error (_ : Path.path_refusal) -> ()
      | Ok path -> Alcotest.failf "%s was read as %s" label (relative ~base_path path))
    [ "the path of his credential", credential
    ; ( "a parent escape toward it"
      , String.concat "/" ([ ".."; ".."; ".."; Runtime_account_home_layout.accounts_dir ] @ bob_home @ [ ".credentials.json" ]) )
    ; "a symlink she made to his home", "bob-home/.credentials.json"
    ]
;;

let () =
  (* The configuration is the one under [.masc], not one the environment names. *)
  Unix.putenv Env_config_core.config_dir_env_key "";
  Alcotest.run
    "keeper_account_home_reach"
    [ ( "lanes"
      , [ Alcotest.test_case "Docker mounts stay out" `Quick test_docker_mounts
        ; Alcotest.test_case "Apple guest mounts stay out" `Quick test_apple_guest_mounts
        ; Alcotest.test_case "Read stays out" `Quick test_read
        ] )
    ]
;;
