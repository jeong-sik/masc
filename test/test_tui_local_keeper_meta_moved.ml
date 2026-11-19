(* A Keeper row change the server announces reads the local Keeper list only
   when that Keeper's metadata file is not the one the last local read
   decoded. A receipt or a candle announces a row change and leaves the file
   as it was. *)

open Alcotest
open Masc

let with_temp_dir prefix f =
  let path = Filename.temp_dir prefix ".workspace" in
  Fun.protect
    ~finally:(fun () -> Fs_compat.remove_tree path)
    (fun () -> f path)

let meta ?(paused = false) name =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc [ "name", `String name; "trace_id", `String ("trace-" ^ name) ])
  with
  | Ok meta -> { meta with paused }
  | Error error -> fail ("meta_of_json failed: " ^ error)

let write config meta =
  match Keeper_meta_store.replace_snapshot config meta with
  | Ok () -> ()
  | Error error -> fail ("write_meta failed: " ^ error)

let read_list base_path = ignore (Masc_tui_loader.read_local_keepers base_path)

let moved base_path name = Masc_tui_loader.local_keeper_meta_moved base_path name

let test_only_a_changed_file_moves () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  with_temp_dir "masc-tui-local-meta-" @@ fun base_path ->
  let config = Workspace.default_config base_path in
  ignore (Workspace.init config ~agent_name:None);
  write config (meta "alpha");
  check bool "a file no read decoded has moved" true (moved base_path "alpha");
  read_list base_path;
  check bool "the file the read decoded has not moved" false (moved base_path "alpha");
  write config (meta ~paused:true "alpha");
  check bool "a rewritten file has moved" true (moved base_path "alpha");
  read_list base_path;
  check bool "after the read it holds still again" false (moved base_path "alpha");
  check bool "a name with no file and no read has not moved" false (moved base_path "ghost");
  let path =
    Filename.concat (Keeper_types_profile.keeper_dir config)
      (Keeper_runtime_root_entry.keeper_basename ~keeper_name:"alpha"
         Keeper_runtime_root_entry.Metadata)
  in
  Sys.remove path;
  check bool "a removed file has moved" true (moved base_path "alpha")

(* The metadata writer replaces the file with a rename. A replacement that
   keeps the size and the modification time is another file all the same. *)
let test_a_same_stat_replacement_moves () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  with_temp_dir "masc-tui-local-meta-same-stat-" @@ fun base_path ->
  let config = Workspace.default_config base_path in
  ignore (Workspace.init config ~agent_name:None);
  write config (meta "alpha");
  let path =
    Filename.concat (Keeper_types_profile.keeper_dir config)
      (Keeper_runtime_root_entry.keeper_basename ~keeper_name:"alpha"
         Keeper_runtime_root_entry.Metadata)
  in
  (* [Unix.utimes] copies a modification time exactly only when it is whole
     seconds. *)
  let stamp = Float.floor (Unix.gettimeofday ()) -. 1. in
  Unix.utimes path stamp stamp;
  read_list base_path;
  check bool "the file the read decoded has not moved" false (moved base_path "alpha");
  let before = Unix.stat path in
  let replacement = path ^ ".replacement" in
  let bytes = In_channel.with_open_bin path In_channel.input_all in
  Out_channel.with_open_bin replacement (fun channel -> Out_channel.output_string channel bytes);
  Unix.utimes replacement stamp stamp;
  Unix.rename replacement path;
  let after = Unix.stat path in
  check bool "the replacement keeps size and modification time" true
    (before.Unix.st_size = after.Unix.st_size
     && Float.equal before.Unix.st_mtime after.Unix.st_mtime);
  check bool "a same-stat replacement has moved" true (moved base_path "alpha")

let () =
  run "tui_local_keeper_meta_moved"
    [ ( "local keeper list",
        [ test_case "only a changed file moves" `Quick test_only_a_changed_file_moves;
          test_case "a same-stat replacement moves" `Quick test_a_same_stat_replacement_moves ] ) ]
