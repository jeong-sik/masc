(** Focused standalone regression for Docker-profile keeper_fs_edit writes.

    This avoids the large shared [tests] stanza while still exercising the
    real handler path that used to rely only on allowed_paths resolution. *)

module Coord = Masc_mcp.Coord
module Fs_compat = Fs_compat
module Json = Yojson.Safe.Util
module Keeper_exec_fs = Masc_mcp.Keeper_exec_fs
module Keeper_registry = Masc_mcp.Keeper_registry
module Keeper_sandbox = Masc_mcp.Keeper_sandbox
module Keeper_types = Masc_mcp.Keeper_types

let temp_dir () =
  let d = Filename.temp_file "keeper_fs_write_containment_" "" in
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
      ]
  in
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok meta -> meta
  | Error e -> Alcotest.fail e
;;

let with_eio_fs f =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Process_eio.init
    ~cwd_default:(Eio.Stdenv.cwd env)
    ~proc_mgr:(Eio.Stdenv.process_mgr env)
    ~clock:(Eio.Stdenv.clock env);
  f ()
;;

let setup f =
  with_eio_fs
  @@ fun () ->
  let base = temp_dir () in
  ensure_dir (Filename.concat base Common.masc_dirname);
  Fun.protect
    ~finally:(fun () -> cleanup_dir base)
    (fun () ->
       Keeper_registry.clear ();
       let config = Coord.default_config base in
       let meta = make_meta "tester" in
       let playground = Keeper_sandbox.host_root_abs_of_meta ~config meta in
       ensure_dir playground;
       f ~config ~meta ~playground)
;;

let parse raw = Yojson.Safe.from_string raw

let parse_ok raw =
  parse raw |> Json.member "ok" |> Json.to_bool_option |> Option.value ~default:false
;;

let parse_error raw = parse raw |> Json.member "error" |> Json.to_string_option

let contains_substring ~needle text =
  let nlen = String.length needle in
  let tlen = String.length text in
  let rec loop i =
    if nlen = 0
    then true
    else if i + nlen > tlen
    then false
    else if String.sub text i nlen = needle
    then true
    else loop (i + 1)
  in
  loop 0
;;

let test_docker_write_blocks_project_root_even_if_allowlisted () =
  setup
  @@ fun ~config ~meta ~playground:_ ->
  let meta = { meta with allowed_paths = [ config.base_path ] } in
  let path = Filename.concat config.base_path "root-write.txt" in
  let raw =
    Keeper_exec_fs.handle_keeper_fs_edit
      ~turn_sandbox_factory:None
      ~config
      ~keeper_name:meta.name
      ~args:
        (`Assoc
            [ "path", `String path
            ; "mode", `String "overwrite"
            ; "content", `String "must not land"
            ])
  in
  Alcotest.(check bool) "ok=false" false (parse_ok raw);
  (match parse_error raw with
   | None -> Alcotest.fail "expected containment error"
   | Some msg ->
     Alcotest.(check bool)
       "error mentions symmetric sandbox guard"
       true
       (contains_substring ~needle:"symmetric_sandbox_blocked" msg));
  Alcotest.(check bool) "root file not created" false (Fs_compat.file_exists path)
;;

let test_docker_write_allows_playground () =
  setup
  @@ fun ~config ~meta ~playground ->
  let path = Filename.concat playground "mind/allowed.txt" in
  ensure_dir (Filename.dirname path);
  let raw =
    Keeper_exec_fs.handle_keeper_fs_edit
      ~turn_sandbox_factory:None
      ~config
      ~keeper_name:meta.name
      ~args:
        (`Assoc
            [ "path", `String path
            ; "mode", `String "overwrite"
            ; "content", `String "allowed"
            ])
  in
  if not (parse_ok raw) then Alcotest.failf "expected ok response, got: %s" raw;
  Alcotest.(check string) "content landed" "allowed" (Fs_compat.load_file path)
;;

let () =
  Alcotest.run
    "Keeper_fs_write_containment"
    [ ( "fs_edit"
      , [ Alcotest.test_case
            "docker write blocks project root even if allowlisted"
            `Quick
            test_docker_write_blocks_project_root_even_if_allowlisted
        ; Alcotest.test_case
            "docker write allows playground"
            `Quick
            test_docker_write_allows_playground
        ] )
    ]
;;
