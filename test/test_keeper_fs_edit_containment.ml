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

(* The bare string-returning wrapper handle_file_write (formerly exported
   from [Keeper_tool_filesystem_runtime]) was retired: it had zero
   production callers
   ([keeper_tool_runtime.ml] calls [handle_file_write_with_outcome]
   directly). This test-local shim reproduces its [.raw_output] projection
   so the assertions below keep exercising the real production entry
   point. *)
let handle_file_write
      ~turn_sandbox_factory
      ~config
      ~meta
      ~publication_recovery
      ?continuation_channel
      ?gate_context
      ?gate_grant
      ~args
      ()
  =
  (Keeper_tool_filesystem_runtime.handle_file_write_with_outcome
     ~turn_sandbox_factory
     ~config
     ~meta
     ~publication_recovery
     ?continuation_channel
     ?gate_context
     ?gate_grant
     ~args
     ())
    .raw_output
;;

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
      ; "agent_name", `String ("keeper-" ^ name ^ "-agent")
      ; "trace_id", `String ("trace-" ^ name)
      ; "always_allow", `Bool false
      ]
  in
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok meta ->
    { meta with sandbox_profile = Keeper_types_profile_sandbox.Docker }
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
       Keeper_registry.For_testing.clear ();
       let config = Workspace.default_config base in
       let meta = make_meta "tester" in
       let playground = Keeper_sandbox.host_root_abs_of_meta ~config meta in
       ensure_dir playground;
       let (_registered : Keeper_registry.registry_entry) =
         Keeper_registry.For_testing.register ~base_path:base meta.name meta
       in
       Masc_test_deps.with_publication_recovery_registry
         ~sw
         ~fs
         ~registry_root:(Workspace.masc_root_dir config)
       @@ fun registry ->
       let publication_recovery =
         { Masc.Keeper_publication_recovery_availability.provider =
             Masc_test_deps.publication_recovery_provider registry
         ; keeper_name = meta.name
         }
       in
       f ~config ~meta ~playground ~publication_recovery)
;;

let parse raw = Yojson.Safe.from_string raw

let parse_ok raw =
  parse raw |> Json.member "ok" |> Json.to_bool_option |> Option.value ~default:false
;;

let test_docker_write_defers_explicit_root () =
  setup
  @@ fun ~config ~meta ~playground:_ ~publication_recovery ->
  let meta = { meta with allowed_paths = [ config.base_path ] } in
  let path = Filename.concat config.base_path "root-write.txt" in
  let raw =
    handle_file_write
      ~turn_sandbox_factory:None
      ~config
      ~meta
      ~publication_recovery
      ~args:
        (`Assoc
            [ "path", `String path
            ; "mode", `String "overwrite"
            ; "content", `String "must not land"
            ])
      ()
  in
  Alcotest.(check bool) "write deferred" false (parse_ok raw);
  Alcotest.(check bool) "content did not land" false (Sys.file_exists path)
;;

let test_docker_write_allows_playground_without_gate () =
  setup
  @@ fun ~config ~meta ~playground ~publication_recovery ->
  let path = Filename.concat playground "scratch/allowed.txt" in
  ensure_dir (Filename.dirname path);
  let raw =
    handle_file_write
      ~turn_sandbox_factory:None
      ~config
      ~meta
      ~publication_recovery
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

let test_docker_write_rejects_playground_symlink_escape () =
  setup
  @@ fun ~config ~meta ~playground ~publication_recovery ->
  let outside = Filename.concat config.base_path "outside" in
  ensure_dir outside;
  let link = Filename.concat playground "escape" in
  Unix.symlink outside link;
  let escaped = Filename.concat link "escaped.txt" in
  let raw =
    handle_file_write
      ~turn_sandbox_factory:None
      ~config
      ~meta
      ~publication_recovery
      ~args:
        (`Assoc
            [ "path", `String escaped
            ; "mode", `String "overwrite"
            ; "content", `String "must not escape"
            ])
      ()
  in
  Alcotest.(check bool) "escape rejected" false (parse_ok raw);
  Alcotest.(check bool)
    "outside file absent"
    false
    (Sys.file_exists (Filename.concat outside "escaped.txt"))
;;

let test_docker_write_rejects_parent_traversal () =
  setup
  @@ fun ~config ~meta ~playground ~publication_recovery ->
  let escaped = Filename.concat playground "../escaped.txt" in
  let raw =
    handle_file_write
      ~turn_sandbox_factory:None
      ~config
      ~meta
      ~publication_recovery
      ~args:
        (`Assoc
            [ "path", `String escaped
            ; "mode", `String "overwrite"
            ; "content", `String "must not escape"
            ])
      ()
  in
  Alcotest.(check bool) "traversal rejected" false (parse_ok raw);
  Alcotest.(check bool)
    "traversal file absent"
    false
    (Sys.file_exists escaped)
;;

let () =
  Alcotest.run
    "Keeper_fs_edit_containment"
    [ ( "fs_edit"
      , [ Alcotest.test_case
            "docker write defers explicit root outside playground"
            `Quick
            test_docker_write_defers_explicit_root
        ; Alcotest.test_case
            "docker write allows playground without gate"
            `Quick
            test_docker_write_allows_playground_without_gate
        ; Alcotest.test_case
            "docker write rejects playground symlink escape"
            `Quick
            test_docker_write_rejects_playground_symlink_escape
        ; Alcotest.test_case
            "docker write rejects parent traversal"
            `Quick
            test_docker_write_rejects_parent_traversal
        ] )
    ]
;;
