(** Focused standalone regression for Docker-profile tool_edit_file writes.

    This avoids the large shared [tests] stanza while still exercising the
    real handler path that used to rely only on allowed_paths resolution. *)

module Workspace = Masc.Workspace
module Fs_compat = Fs_compat
module Json = Yojson.Safe.Util
module Keeper_tool_filesystem_runtime = Masc.Keeper_tool_filesystem_runtime
module Keeper_registry = Masc.Keeper_registry
module Keeper_sandbox = Masc.Keeper_sandbox
module Keeper_types = Keeper_types

let temp_dir () =
  let d = Filename.temp_file "tool_edit_file_containment_" "" in
  Unix.unlink d;
  Unix.mkdir d 0o755;
  d
;;

let cleanup_dir dir =
  let rec rm path =
    match Unix.lstat path with
    | { Unix.st_kind = Unix.S_DIR; _ } ->
      Array.iter (fun n -> rm (Filename.concat path n)) (Sys.readdir path);
      Unix.rmdir path
    | _ -> Unix.unlink path
    | exception Unix.Unix_error _ -> ()
  in
  try rm dir with
  | _ -> ()
;;

let rec ensure_dir path =
  if path = "" || path = "." || path = "/"
  then ()
  else if Sys.file_exists path
  then ()
  else (
    let parent = Filename.dirname path in
    if parent <> path then ensure_dir parent;
    Unix.mkdir path 0o755)
;;

let make_meta name =
  let json =
    `Assoc
      [ "name", `String name
      ; "agent_name", `String ("agent-" ^ name)
      ; "trace_id", `String ("trace-" ^ name)
      ; "goal", `String "write containment test"
      ; "sandbox_profile", `String "docker"
      ; "always_allow", `Bool true
      ]
  in
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok meta -> meta
  | Error e -> Alcotest.fail e
;;

let with_eio_fs f =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let fs = Eio.Stdenv.fs env in
  Fs_compat.set_fs fs;
  Process_eio.init
    ~cwd_default:(Eio.Stdenv.cwd env)
    ~proc_mgr:(Eio.Stdenv.process_mgr env)
    ~clock:(Eio.Stdenv.clock env);
  f ~fs ~sw ()
;;

let setup f =
  with_eio_fs
  @@ fun ~fs ~sw () ->
  let base = temp_dir () in
  ensure_dir (Filename.concat base Common.masc_dirname);
  Fun.protect
    ~finally:(fun () -> cleanup_dir base)
    (fun () ->
       Keeper_registry.clear ();
       let config = Workspace.default_config base in
       let meta = { (make_meta "tester") with always_allow = Some true } in
       let playground = Keeper_sandbox.host_root_abs_of_meta ~config meta in
       ensure_dir playground;
       let (_registered : Keeper_registry.registry_entry) =
         Keeper_registry.register ~base_path:base meta.name meta
       in
       let registry =
         match
           Fs_compat.open_publication_recovery_registry
             ~sw
             ~registry_root:Eio.Path.(fs / Workspace.masc_root_dir config)
         with
         | Ok registry -> registry
         | Error error ->
           Alcotest.fail
             (Fs_compat.publication_recovery_registry_error_to_string error)
       in
       match
         Fs_compat.with_publication_recovery_lane
           ~registry
           ~owner:meta.name
           (fun publication_recovery_access ->
              f ~config ~meta ~playground ~publication_recovery_access)
       with
       | Ok value -> value
       | Error error ->
         Alcotest.fail
           (Fs_compat.publication_recovery_lane_open_error_to_string error))
;;

let parse raw = Yojson.Safe.from_string raw

let parse_ok raw =
  parse raw |> Json.member "ok" |> Json.to_bool_option |> Option.value ~default:false
;;

let test_docker_write_allows_explicit_root () =
  setup
  @@ fun ~config ~meta ~playground:_ ~publication_recovery_access ->
  let meta = { meta with allowed_paths = [ config.base_path ] } in
  Keeper_registry.update_meta ~base_path:config.base_path meta.name meta;
  let path = Filename.concat config.base_path "root-write.txt" in
  let raw =
    Keeper_tool_filesystem_runtime.handle_file_write
      ~turn_sandbox_factory:None
      ~config
      ~meta
      ~publication_recovery_access
      ~args:
        (`Assoc
            [ "path", `String path
            ; "mode", `String "overwrite"
            ; "content", `String "must not land"
            ])
      ()
  in
  if not (parse_ok raw) then Alcotest.failf "expected ok response, got: %s" raw;
  Alcotest.(check string) "content landed" "must not land" (Fs_compat.load_file path)
;;

let test_docker_write_allows_playground () =
  setup
  @@ fun ~config ~meta ~playground ~publication_recovery_access ->
  let path = Filename.concat playground "mind/allowed.txt" in
  ensure_dir (Filename.dirname path);
  let raw =
    Keeper_tool_filesystem_runtime.handle_file_write
      ~turn_sandbox_factory:None
      ~config
      ~meta
      ~publication_recovery_access
      ~args:
        (`Assoc
            [ "path", `String path
            ; "mode", `String "overwrite"
            ; "content", `String "allowed"
            ])
      ()
  in
  if not (parse_ok raw) then Alcotest.failf "expected ok response, got: %s" raw;
  Alcotest.(check string) "content landed" "allowed" (Fs_compat.load_file path)
;;

let () =
  Alcotest.run
    "Keeper_fs_edit_containment"
    [ ( "fs_edit"
      , [ Alcotest.test_case
            "docker write allows explicit root outside playground"
            `Quick
            test_docker_write_allows_explicit_root
        ; Alcotest.test_case
            "docker write allows playground"
            `Quick
            test_docker_write_allows_playground
        ] )
    ]
;;
