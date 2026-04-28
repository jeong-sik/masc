open Alcotest
open Masc_mcp

let rec rm_rf path =
  if Sys.file_exists path then
    match (Unix.lstat path).Unix.st_kind with
    | Unix.S_DIR ->
        Sys.readdir path
        |> Array.iter (fun name -> rm_rf (Filename.concat path name));
        Unix.rmdir path
    | _ ->
        Unix.unlink path

let with_temp_dir prefix f =
  let dir = Filename.temp_file prefix "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  Fun.protect ~finally:(fun () -> try rm_rf dir with _ -> ()) (fun () -> f dir)

let write_keeper_meta ~config ~name ~shared_memory_scope =
  let agent_name = Printf.sprintf "keeper-%s-agent" name in
  let meta_json =
    `Assoc
      [
        ("name", `String name);
        ("agent_name", `String agent_name);
        ("trace_id", `String ("trace-" ^ name));
        ("goal", `String "test");
        ("shared_memory_scope", `String shared_memory_scope);
      ]
  in
  let meta =
    match Masc_test_deps.meta_of_json_fixture meta_json with
    | Ok meta -> meta
    | Error err -> fail ("meta_of_json failed: " ^ err)
  in
  match Keeper_types.write_meta ~force:true config meta with
  | Ok () -> agent_name
  | Error err -> fail ("write_meta failed: " ^ err)

let dispatch ~config ~agent_name ~name args =
  match Tool_team_memory.dispatch ~config ~agent_name ~name ~args with
  | Some result -> result
  | None -> fail ("unexpected missing dispatch: " ^ name)

let json_result_exn = function
  | true, body -> Yojson.Safe.from_string body
  | false, err -> fail err

let test_write_read_search () =
  with_temp_dir "team-memory-room" @@ fun base_path ->
  Fs_compat.clear_fs ();
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let config = Coord.default_config base_path in
  let agent_name =
    write_keeper_meta ~config ~name:"room-alpha" ~shared_memory_scope:"room"
  in
  let write_args =
    `Assoc
      [
        ("room", `String "default");
        ("key", `String "notes/demo.md");
        ("content", `String "hello shared team memory");
      ]
  in
  ignore
    (json_result_exn
       (dispatch ~config ~agent_name ~name:"masc_team_memory_write" write_args));
  let read_json =
    json_result_exn
      (dispatch ~config ~agent_name ~name:"masc_team_memory_read"
         (`Assoc
            [
              ("room", `String "default");
              ("key", `String "notes/demo.md");
            ]))
  in
  let open Yojson.Safe.Util in
  check string "read content" "hello shared team memory"
    (read_json |> member "content" |> to_string);
  let search_json =
    json_result_exn
      (dispatch ~config ~agent_name ~name:"masc_team_memory_search"
         (`Assoc
            [
              ("room", `String "default");
              ("query", `String "shared");
            ]))
  in
  check int "search match count" 1
    (search_json |> member "matches" |> to_list |> List.length);
  check string "search key" "notes/demo.md"
    (search_json |> member "matches" |> index 0 |> member "key" |> to_string)

let test_traversal_blocked () =
  with_temp_dir "team-memory-traversal" @@ fun base_path ->
  Fs_compat.clear_fs ();
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let config = Coord.default_config base_path in
  let agent_name =
    write_keeper_meta ~config ~name:"room-alpha" ~shared_memory_scope:"room"
  in
  let ok, err =
    dispatch ~config ~agent_name ~name:"masc_team_memory_read"
      (`Assoc
         [
           ("room", `String "default");
           ("key", `String "../outside.txt");
         ])
  in
  check bool "blocked" false ok;
  check bool "mentions traversal" true
    (String_util.contains_substring err "traversal")

let test_secret_like_write_blocked () =
  with_temp_dir "team-memory-secret" @@ fun base_path ->
  Fs_compat.clear_fs ();
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let config = Coord.default_config base_path in
  let agent_name =
    write_keeper_meta ~config ~name:"room-alpha" ~shared_memory_scope:"room"
  in
  let ok, err =
    dispatch ~config ~agent_name ~name:"masc_team_memory_write"
      (`Assoc
         [
           ("room", `String "default");
           ("key", `String "secrets/note.txt");
           ("content",
             `String "Authorization: Bearer sk-secret-token-1234567890");
         ])
  in
  check bool "blocked" false ok;
  check bool "mentions secrets" true
    (String_util.contains_substring err "contain secrets")

let test_symlink_escape_blocked () =
  with_temp_dir "team-memory-symlink" @@ fun base_path ->
  Fs_compat.clear_fs ();
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let config = Coord.default_config base_path in
  let agent_name =
    write_keeper_meta ~config ~name:"room-alpha" ~shared_memory_scope:"room"
  in
  let root = Tool_team_memory.team_memory_root ~config "default" in
  Fs_compat.mkdir_p root;
  let outside_path = Filename.concat base_path "outside.txt" in
  (match Fs_compat.save_file_atomic outside_path "outside" with
  | Ok () -> ()
  | Error err -> fail err);
  let link_path = Filename.concat root "escape.txt" in
  Unix.symlink outside_path link_path;
  let ok, err =
    dispatch ~config ~agent_name ~name:"masc_team_memory_read"
      (`Assoc
         [
           ("room", `String "default");
           ("key", `String "escape.txt");
         ])
  in
  check bool "blocked" false ok;
  check bool "mentions symlink" true
    (String_util.contains_substring err "symlink")

let test_disabled_scope_blocked () =
  with_temp_dir "team-memory-disabled" @@ fun base_path ->
  Fs_compat.clear_fs ();
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let config = Coord.default_config base_path in
  let agent_name =
    write_keeper_meta ~config ~name:"room-alpha" ~shared_memory_scope:"disabled"
  in
  let ok, err =
    dispatch ~config ~agent_name ~name:"masc_team_memory_read"
      (`Assoc
         [
           ("room", `String "default");
           ("key", `String "notes/demo.md");
         ])
  in
  check bool "blocked" false ok;
  check bool "mentions shared_memory_scope" true
    (String_util.contains_substring err "shared_memory_scope=room")

let test_non_keeper_agent_blocked () =
  with_temp_dir "team-memory-non-keeper" @@ fun base_path ->
  Fs_compat.clear_fs ();
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let config = Coord.default_config base_path in
  let ok, err =
    dispatch ~config ~agent_name:"operator-human" ~name:"masc_team_memory_read"
      (`Assoc
         [
           ("room", `String "default");
           ("key", `String "notes/demo.md");
         ])
  in
  check bool "blocked" false ok;
  check bool "mentions keeper-only" true
    (String_util.contains_substring err "keeper-only")

let test_non_default_room_blocked () =
  with_temp_dir "team-memory-room-validation" @@ fun base_path ->
  Fs_compat.clear_fs ();
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let config = Coord.default_config base_path in
  let agent_name =
    write_keeper_meta ~config ~name:"room-alpha" ~shared_memory_scope:"room"
  in
  let ok, err =
    dispatch ~config ~agent_name ~name:"masc_team_memory_search"
      (`Assoc
         [
           ("room", `String "incident-alpha");
           ("query", `String "shared");
         ])
  in
  check bool "blocked" false ok;
  check bool "mentions default namespace" true
    (String_util.contains_substring err "room must be 'default'")

let () =
  run "team_memory"
    [
      ( "crud",
        [
          test_case "write read search" `Quick test_write_read_search;
        ] );
      ( "guards",
        [
          test_case "traversal blocked" `Quick test_traversal_blocked;
          test_case "secret-like write blocked" `Quick
            test_secret_like_write_blocked;
          test_case "symlink escape blocked" `Quick
            test_symlink_escape_blocked;
          test_case "disabled scope blocked" `Quick
            test_disabled_scope_blocked;
          test_case "non-keeper agent blocked" `Quick
            test_non_keeper_agent_blocked;
          test_case "non-default room blocked" `Quick
            test_non_default_room_blocked;
        ] );
    ]
