open Alcotest
open Masc
module Config = Lane_addon_config

let unwrap = function Ok value -> value | Error message -> fail message
let write path bytes = Out_channel.with_open_bin path (fun channel -> output_string channel bytes)
let rec remove path =
  match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR ->
      Sys.readdir path |> Array.iter (fun name -> remove (Filename.concat path name));
      Unix.rmdir path
  | _ -> Sys.remove path
let with_directory f =
  let root = Filename.temp_dir "lane-declaration-" "" in
  Fun.protect ~finally:(fun () -> remove root) (fun () ->
    let packages = Filename.concat root "packages" in
    let declarations = Filename.concat root "declarations" in
    Unix.mkdir packages 0o700;
    Unix.mkdir declarations 0o700;
    f root packages declarations)
let package ?(title = "Example observer") () =
  Printf.sprintf {|id = "example"
revision = "1"
title = %S
image = "example-observer:1"
command = ["python3", "server.py"]
contributions = ["observe"]
[resources]
cpus = 0.5
memory_bytes = 134217728
pids = 16
max_reply_bytes = 4194304
|} title
let install_package packages =
  let path = Filename.concat packages "lane.toml" in
  write path (package ());
  path
let declaration ?(id = "frames") ?(run_id = "game") ?(extra = "") binding =
  Printf.sprintf {|id = %S
run_id = %S
manifest_path = "../packages/lane.toml"
%s
%s
|} id run_id extra binding
let msx_binding = {|[binding]
sources = [{source_id = "machine", kind = "msx_capture"}]
|}
let only_declaration (snapshot : Config.snapshot) = match snapshot.declarations with
  | [declaration] -> declaration
  | values -> failf "expected one declaration, found %d" (List.length values)
let check_error label path = check bool label true (Result.is_error (Config.load_file ~path))

let relative_package_and_source () = with_directory (fun _root packages directory ->
  let manifest = install_package packages in
  let path = Filename.concat directory "frames.toml" in
  write path (declaration {|[binding]
sources = [{source_id = "metrics", kind = "snapshot_file", path = "../measurements.json"}]
[binding.settings]
enabled = true
labels = ["first", "second"]
weight = 1.5
count = 3
|});
  let found = unwrap (Config.load_file ~path) in
  check string "package resolves from the declaration directory" (Unix.realpath manifest) found.manifest_path;
  check string "resolved package uses its own directory" (Unix.realpath packages) found.package.directory;
  let open Yojson.Safe.Util in
  let source = found.binding |> member "sources" |> to_list |> List.hd in
  check string "missing snapshot can remain an explicit future source"
    (Filename.concat directory "../measurements.json") (source |> member "path" |> to_string);
  let settings = found.binding |> member "settings" in
  check bool "boolean remains boolean" true (settings |> member "enabled" |> to_bool);
  check int "integer remains integer" 3 (settings |> member "count" |> to_int);
  check (list string) "array order is preserved" ["first"; "second"]
    (settings |> member "labels" |> to_list |> List.map to_string);
  check (float 0.) "float remains float" 1.5 (settings |> member "weight" |> to_float))

let comments_rename_and_key_order () = with_directory (fun _root packages directory ->
  ignore (install_package packages);
  let path = Filename.concat directory "frames.toml" in
  write path (declaration msx_binding);
  let initial = unwrap (Config.load_file ~path) in
  write path {|# comments and table key order do not restart an installation
manifest_path = "../packages/lane.toml"
run_id = "game"
id = "frames"
[binding]
sources = [{kind = "msx_capture", source_id = "machine"}]
|};
  let reordered = unwrap (Config.load_file ~path) in
  check string "semantic revision ignores comments and field order" initial.revision reordered.revision;
  let renamed = Filename.concat directory "renamed.toml" in
  Sys.rename path renamed;
  let snapshot = Config.load ~directory in
  let found = only_declaration snapshot in
  check string "renaming retains stable identity" initial.id found.id;
  check string "renaming does not change semantic revision" initial.revision found.revision;
  check (list string) "discovery tracks the renamed source" [renamed] snapshot.paths;
  check string "applied source path can be updated" renamed found.source_path)

let meaningful_changes () = with_directory (fun _root packages directory ->
  let manifest = install_package packages in
  let path = Filename.concat directory "frames.toml" in
  let binding order = Printf.sprintf {|[binding]
sources = [{source_id = "machine", kind = "msx_capture"}]
labels = [%s]
|} order in
  write path (declaration (binding {|"first", "second"|}));
  let initial = unwrap (Config.load_file ~path) in
  write path (declaration (binding {|"second", "first"|}));
  let reordered = unwrap (Config.load_file ~path) in
  check bool "ordered package settings affect revision" true (initial.revision <> reordered.revision);
  write manifest (package ~title:"Changed output description" ());
  let updated_package = unwrap (Config.load_file ~path) in
  check bool "resolved manifest changes affect revision" true (reordered.revision <> updated_package.revision);
  write path (declaration ~run_id:"another-game" (binding {|"second", "first"|}));
  let updated_run = unwrap (Config.load_file ~path) in
  check bool "world binding changes affect revision" true (updated_package.revision <> updated_run.revision))

let reject_invalid_values () = with_directory (fun _root packages directory ->
  ignore (install_package packages);
  let path = Filename.concat directory "frames.toml" in
  List.iter (fun (label, bytes) -> write path bytes; check_error label path)
    ["unknown top-level field", declaration ~extra:"enabled = true" msx_binding;
     "missing binding", declaration "";
     "empty snapshot path is not expanded into a valid directory",
       declaration {|[binding]
sources = [{source_id = "metrics", kind = "snapshot_file", path = ""}]
|};
     "unknown source kind", declaration {|[binding]
sources = [{source_id = "machine", kind = "invented_source"}]
|};
     "source IDs must be unique", declaration {|[binding]
sources = [{source_id = "machine", kind = "msx_capture"}, {source_id = "machine", kind = "msx_capture"}]
|}];
  List.iter (fun value ->
    write path (declaration (msx_binding ^ "setting = " ^ value ^ "\n"));
    check_error ("unsupported typed TOML setting: " ^ value) path)
    ["nan"; "inf"; "-inf"; "2026-09-12"; "12:30:00"; "2026-09-12T12:30:00";
     "2026-09-12T12:30:00Z"];
  write path (declaration (msx_binding ^ "setting = \"2026-09-12\"\n"));
  check bool "an explicit date string remains package data" true (Result.is_ok (Config.load_file ~path)))

let invalid_files_remain_visible () = with_directory (fun _root packages directory ->
  ignore (install_package packages);
  let valid = Filename.concat directory "a.toml" in
  let malformed = Filename.concat directory "b.toml" in
  let invalid = Filename.concat directory "c.toml" in
  write valid (declaration msx_binding);
  write malformed "id = [ unfinished";
  write invalid (declaration ~id:"invalid" ~extra:"unexpected = true" msx_binding);
  write (Filename.concat directory "editor.tmp") "unfinished";
  let snapshot = Config.load ~directory in
  check bool "schema errors do not conceal directory membership" true snapshot.complete;
  check (list string) "all declared source paths remain visible" [valid; malformed; invalid] snapshot.paths;
  check int "valid independent installation remains available" 1 (List.length snapshot.declarations);
  check int "both rejected files are reported" 2 (List.length snapshot.issues);
  let identified = List.find (fun (issue : Config.issue) -> issue.source_path = invalid) snapshot.issues in
  check (option string) "parsed-invalid file retains its typed identity" (Some "invalid") identified.id)

let duplicates_have_no_winner () = with_directory (fun _root packages directory ->
  ignore (install_package packages);
  let first = Filename.concat directory "a.toml" in
  let second = Filename.concat directory "b.toml" in
  let independent = Filename.concat directory "c.toml" in
  write first (declaration msx_binding);
  write second (declaration msx_binding);
  write independent (declaration ~id:"independent" msx_binding);
  let snapshot = Config.load ~directory in
  check string "only independent configuration survives" "independent" (only_declaration snapshot).id;
  check (list string) "every duplicate source is reported" [first; second]
    (List.map (fun (issue : Config.issue) -> issue.source_path) snapshot.issues);
  check bool "duplicate reports retain identity" true
    (List.for_all (fun (issue : Config.issue) -> issue.id = Some "frames") snapshot.issues);
  write second (declaration ~extra:"unexpected = true" msx_binding);
  let invalid_duplicate = Config.load ~directory in
  check string "invalid duplicate cannot silently elect another winner" "independent"
    (only_declaration invalid_duplicate).id)

let directory_and_read_failures () = with_directory (fun root _packages directory ->
  let absent = Config.load ~directory:(Filename.concat root "absent") in
  check bool "missing declaration directory is a complete empty configuration" true absent.complete;
  check int "no missing-directory issue" 0 (List.length absent.issues);
  let not_directory = Filename.concat root "file" in
  write not_directory "a file";
  let unreadable = Config.load ~directory:not_directory in
  check bool "failed listing cannot authorize detachment" false unreadable.complete;
  check int "failed listing has an issue" 1 (List.length unreadable.issues);
  let rejected = Filename.concat directory "not-a-file.toml" in
  Unix.mkdir rejected 0o700;
  let snapshot = Config.load ~directory in
  check bool "unreadable declaration prevents deletion inference" false snapshot.complete;
  check (list string) "unreadable declaration retains its path" [rejected] snapshot.paths;
  check int "unreadable declaration is reported" 1 (List.length snapshot.issues))

let () = run "Lane Add-on declarative composition"
  ["configuration",
    [test_case "relative package and source preserve typed bindings" `Quick relative_package_and_source;
     test_case "comments, rename and key order preserve identity" `Quick comments_rename_and_key_order;
     test_case "meaningful configuration and package changes alter revision" `Quick meaningful_changes;
     test_case "invalid values remain errors" `Quick reject_invalid_values;
     test_case "malformed files retain membership and identity" `Quick invalid_files_remain_visible;
     test_case "duplicate identities do not elect a winner" `Quick duplicates_have_no_winner;
     test_case "missing and unreadable configuration are distinct" `Quick directory_and_read_failures]]
