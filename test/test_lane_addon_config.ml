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
(* [with_directory] keeps the package folders beside the declarations, so a
   declaration that names a carried package finds it there too. *)
let packages_beside directory = Filename.concat (Filename.dirname directory) "packages"
let load_declaration ~path = Config.load_file ~packages:(packages_beside (Filename.dirname path)) ~path
let load_declarations ~directory = Config.load ~packages:(packages_beside directory) ~directory
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
let check_error label path = check bool label true (Result.is_error (load_declaration ~path))
let contains text needle =
  let width = String.length needle in
  let rec at index =
    index + width <= String.length text
    && (String.sub text index width = needle || at (index + 1)) in
  at 0
(* For a refusal a guide quotes to operators. The row fails when the wording
   changes, so the guide is changed with it. *)
let check_refusal label path quoted = match load_declaration ~path with
  | Ok _ -> failf "%s: the declaration loaded" label
  | Error message ->
      check bool (Printf.sprintf "%s: refused with %S, and the guide quotes %S" label message quoted) true
        (contains message quoted)

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
  let found = unwrap (load_declaration ~path) in
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
  let initial = unwrap (load_declaration ~path) in
  write path {|# comments and table key order do not restart an installation
manifest_path = "../packages/lane.toml"
run_id = "game"
id = "frames"
[binding]
sources = [{kind = "msx_capture", source_id = "machine"}]
|};
  let reordered = unwrap (load_declaration ~path) in
  check string "semantic revision ignores comments and field order" initial.revision reordered.revision;
  check bool "source revision tracks exact edited bytes" true (initial.source_revision <> reordered.source_revision);
  let renamed = Filename.concat directory "renamed.toml" in
  Sys.rename path renamed;
  let snapshot = load_declarations ~directory in
  let found = only_declaration snapshot in
  check string "renaming retains stable identity" initial.id found.id;
  check string "renaming does not change semantic revision" initial.revision found.revision;
  check string "renaming preserves the exact bytes revision" reordered.source_revision found.source_revision;
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
  let initial = unwrap (load_declaration ~path) in
  write path (declaration (binding {|"second", "first"|}));
  let reordered = unwrap (load_declaration ~path) in
  check bool "ordered package settings affect revision" true (initial.revision <> reordered.revision);
  write manifest (package ~title:"Changed output description" ());
  let updated_package = unwrap (load_declaration ~path) in
  check bool "resolved manifest changes affect revision" true (reordered.revision <> updated_package.revision);
  write path (declaration ~run_id:"another-game" (binding {|"second", "first"|}));
  let updated_run = unwrap (load_declaration ~path) in
  check bool "world binding changes affect revision" true (updated_package.revision <> updated_run.revision))

let reject_invalid_values () = with_directory (fun _root packages directory ->
  ignore (install_package packages);
  let path = Filename.concat directory "frames.toml" in
  List.iter (fun (label, bytes) -> write path bytes; check_error label path)
    ["unknown top-level field", declaration ~extra:"unknown_field = true" msx_binding;
     "duplicate declaration identity key", "id = \"duplicate\"\n" ^ declaration msx_binding;
     "duplicate declaration binding key", declaration (msx_binding ^ "sources=[]\n");
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
  check bool "an explicit date string remains package data" true (Result.is_ok (load_declaration ~path));
  (* #41135 introduced the enabled deployment flag: a valid boolean must be
     accepted, not rejected by the unknown-field guard. *)
  write path (declaration ~extra:"enabled = false" msx_binding);
  let disabled = unwrap (load_declaration ~path) in
  check bool "enabled flag is accepted" false disabled.enabled)

let invalid_files_remain_visible () = with_directory (fun _root packages directory ->
  ignore (install_package packages);
  let valid = Filename.concat directory "a.toml" in
  let malformed = Filename.concat directory "b.toml" in
  let invalid = Filename.concat directory "c.toml" in
  write valid (declaration msx_binding);
  write malformed "id = [ unfinished";
  write invalid (declaration ~id:"invalid" ~extra:"unexpected = true" msx_binding);
  write (Filename.concat directory "editor.tmp") "unfinished";
  let snapshot = load_declarations ~directory in
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
  let snapshot = load_declarations ~directory in
  check string "only independent configuration survives" "independent" (only_declaration snapshot).id;
  check (list string) "every duplicate source is reported" [first; second]
    (List.map (fun (issue : Config.issue) -> issue.source_path) snapshot.issues);
  check bool "duplicate reports retain identity" true
    (List.for_all (fun (issue : Config.issue) -> issue.id = Some "frames") snapshot.issues);
  write second (declaration ~extra:"unexpected = true" msx_binding);
  let invalid_duplicate = load_declarations ~directory in
  check string "invalid duplicate cannot silently elect another winner" "independent"
    (only_declaration invalid_duplicate).id)

let directory_and_read_failures () = with_directory (fun root _packages directory ->
  let absent = load_declarations ~directory:(Filename.concat root "absent") in
  check bool "missing declaration directory is a complete empty configuration" true absent.complete;
  check int "no missing-directory issue" 0 (List.length absent.issues);
  let not_directory = Filename.concat root "file" in
  write not_directory "a file";
  let unreadable = load_declarations ~directory:not_directory in
  check bool "failed listing cannot authorize detachment" false unreadable.complete;
  check int "failed listing has an issue" 1 (List.length unreadable.issues);
  let rejected = Filename.concat directory "not-a-file.toml" in
  Unix.mkdir rejected 0o700;
  let snapshot = load_declarations ~directory in
  check bool "unreadable declaration prevents deletion inference" false snapshot.complete;
  check (list string) "unreadable declaration retains its path" [rejected] snapshot.paths;
  check int "unreadable declaration is reported" 1 (List.length snapshot.issues))

let output_ports_are_typed_and_revisioned () = with_directory (fun _root packages directory ->
  let manifest = install_package packages in
  let path = Filename.concat directory "frames.toml" in
  write path (declaration msx_binding);
  let install ports = write manifest (package () ^ ports); load_declaration ~path in
  let initial = unwrap (install {|
[world.outputs.frames]
lanes = ["msx/frame", "msx/state"]
[world.outputs.statistics]
all_lanes = true
|}) in
  let open Lane_addon_types in
  check bool "manifest has exact typed port selections" true
    (initial.package.outputs = ["frames", Selected_lanes ["msx/frame"; "msx/state"]; "statistics", All_lanes]);
  let reordered = unwrap (install {|
# Table order and membership order are not port identity.
[world.outputs.statistics]
all_lanes = true
[world.outputs.frames]
lanes = ["msx/state", "msx/frame"]
|}) in
  check string "port and selected-lane ordering preserve semantic revision" initial.revision reordered.revision;
  let changed = unwrap (install "\n[world.outputs.frames]\nlanes=[\"msx/state\"]\n") in
  check bool "mapping change alters the resolved configuration revision" true
    (initial.revision <> changed.revision);
  check string "package author's revision need not change to observe a mapping edit"
    initial.package.revision changed.package.revision;
  List.iter (fun ports -> check bool ("reject invalid output ports: " ^ ports) true
    (Result.is_error (install ports))) [
      "\n[world.outputs]\n";
      "\n[world.outputs.\"\"]\nall_lanes=true\n";
      "\n[world.outputs.frames]\nlanes=[]\n";
      "\n[world.outputs.frames]\nlanes=[\"\"]\n";
      "\n[world.outputs.frames]\nlanes=[\"msx/frame\",\"msx/frame\"]\n";
      "\n[world.outputs.frames]\nlanes=[1]\n";
      "\n[world.outputs.frames]\nall_lanes=false\n";
      "\n[world.outputs.frames]\nlanes=[\"msx/frame\"]\nall_lanes=true\n";
      "\n[world.outputs.frames]\nunknown=true\n";
      "\n[world.outputs]\nframes={all_lanes=true}\nframes={all_lanes=true}\n" ];
  write manifest (package ());
  List.iter (fun extra ->
    write path (declaration (Printf.sprintf {|[binding]
sources=[{source_id="upstream",kind="lane_output",installation_id="producer",selection="latest_completed",%s}]
|} extra)); check_error ("invalid output selector: " ^ extra) path)
    ["output_id=\"\""; "output_id=1"; "output=\"frames\""])

let package_interface () = with_directory (fun _root packages directory ->
  let manifest = install_package packages in
  let interface = {|
[interface]
binding_schema = '''{"type":"object","properties":{"sources":{"type":"array","items":{"type":"object","properties":{"source_id":{"type":"string"},"kind":{"type":"string"}},"required":["source_id","kind"],"additionalProperties":false}},"limit":{"type":"integer","minimum":1}},"required":["sources","limit"],"additionalProperties":false}'''
presentation = '''{"description":"Compare reported data","readings":[{"lane_id":"quality","path":["missing"],"label":"Missing records","unit":"records","format":"number"}]}'''
|} in
  write manifest (package () ^ "\n" ^ interface);
  let path = Filename.concat directory "quality.toml" in
  write path (declaration (msx_binding ^ "limit = 2\n"));
  let initial = unwrap (load_declaration ~path) in
  check int "package declares one display reading" 1 (List.length initial.package.presentation.readings);
  write path (declaration (msx_binding ^ "limit = 0\n"));
  check_error "invalid package binding rejected before worker install" path;
  write path (declaration msx_binding);
  check_error "missing required package binding rejected" path)

let refresh_policy_is_explicit () = with_directory (fun _root packages directory ->
  let manifest = install_package packages in
  let path = Filename.concat directory "refresh.toml" in
  write path (declaration msx_binding);
  let initial = unwrap (load_declaration ~path) in
  check bool "omitted refresh policy preserves every callback" true
    (initial.package.refresh_policy=Lane_addon_types.Every_hint);
  write manifest (package () ^ "\n[interface]\nrefresh_policy = \"source_changes\"\n");
  let opted_in = unwrap (load_declaration ~path) in
  check bool "suppression requires a typed package opt-in" true
    (opted_in.package.refresh_policy=Lane_addon_types.Source_changes);
  check bool "refresh policy changes the applied configuration identity" false
    (initial.revision=opted_in.revision);
  write manifest (package () ^ "\n[interface]\nrefresh_policy = \"guess\"\n");
  check_error "unknown refresh policy is rejected" path)

(* A browser_document source names the browser Add-on installation it reads.
   A declaration written before that field is refused when it is read; it is
   not attached with a source that names no browser. *)
let browser_document_names_its_browser_installation () = with_directory (fun _root packages directory ->
  ignore (install_package packages);
  let path = Filename.concat directory "reader.toml" in
  let page installation = Printf.sprintf {|[binding]
sources = [{source_id = "page", kind = "browser_document",%s lane = "live", client_id = "0c000000-0000-4000-8000-000000000001", tab_id = 4, target_id = "fixture", environment = "fixture", request_id = "read"}]
|} installation in
  write path (declaration (page ""));
  check_error "a document source without its browser installation is refused" path;
  write path (declaration (page {| installation_id = "",|}));
  check_error "a blank browser installation is refused" path;
  write path (declaration (page {| installation_id = "browser-ego",|}));
  ignore (unwrap (load_declaration ~path)))


(* The shipped DOS chain: every package declares the binding contract that
   `load_file` enforces, and the checked-in declarations satisfy it. Without
   a contract a wrong binding only failed inside the worker, after the
   container had started, and the guided installer had nothing to offer. *)
let repo_file relative = match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root -> Filename.concat root relative
  | None -> Filename.concat (Filename.dirname Sys.executable_name) (Filename.concat ".." relative)
let shipped_dos_chain_declares_binding_contracts () =
  let shipped = [
    "addons/dos-world/install.toml", "dos-world", "dos-demo";
    "docs/examples/lane-addons/dos-value-difference.toml", "value-difference", "dos-value-difference";
    "docs/examples/lane-addons/dos-value-statistics.toml", "output-statistics", "dos-value-statistics";
    "docs/examples/lane-addons/dos-statistics.toml", "output-statistics", "dos-statistics";
    "docs/examples/lane-addons/output-statistics.toml", "output-statistics", "output-statistics"] in
  List.iter (fun (relative, addon_id, id) ->
    let loaded = unwrap (load_declaration ~path:(repo_file relative)) in
    check string ("declaration " ^ relative ^ " names its package") addon_id loaded.package.id;
    check string ("declaration " ^ relative ^ " keeps its id") id loaded.id;
    check bool (addon_id ^ " declares a binding contract") true (Option.is_some loaded.package.binding_schema))
    shipped;
  with_directory (fun _root _packages directory ->
    let manifest name = Unix.realpath (repo_file ("addons/" ^ name ^ "/lane.toml")) in
    let path = Filename.concat directory "candidate.toml" in
    let candidate ~package body = write path (Printf.sprintf {|id = "candidate"
run_id = "dos-demo"
manifest_path = %S
%s|} (manifest package) body) in
    let source = {|[[binding.sources]]
source_id = "guest"
kind = "lane_output"
installation_id = "dos-demo"
output_id = "guest"
selection = "latest_completed"
|} in
    candidate ~package:"value-difference" ("[binding]\nfield = \"counter\"\nunit = \"count\"\n" ^ source);
    ignore (unwrap (load_declaration ~path));
    candidate ~package:"value-difference" ("[binding]\nunit = \"count\"\n" ^ source);
    check_error "value-difference without the compared field is rejected before install" path;
    candidate ~package:"value-difference" ("[binding]\nfield = \"counter\"\nunit = \"count\"\nwindow = 3\n" ^ source);
    check_error "value-difference rejects a binding key the package does not read" path;
    candidate ~package:"output-statistics" ("[binding]\n" ^ source);
    ignore (unwrap (load_declaration ~path));
    candidate ~package:"output-statistics" "[binding]\nsources = [{source_id = \"game\", kind = \"msx_capture\"}]\n";
    check_error "output-statistics accepts lane_output inputs only" path;
    candidate ~package:"dos-world" "[binding]\nsources = []\n";
    ignore (unwrap (load_declaration ~path));
    candidate ~package:"dos-world" ("[binding]\n" ^ source);
    check_error "dos-world takes no external source" path)

(* The shipped operator quiz: the example declaration loads with the package's
   own manifest, its record grants parse as operator-owned grants, and the
   binding contract refuses a binding without the time zone R is counted in. *)
let shipped_operator_quiz_declaration_loads () =
  let loaded = unwrap (load_declaration ~path:(repo_file "docs/examples/lane-addons/operator-quiz.toml")) in
  let package = loaded.package in
  check string "the declaration names the package" "operator-quiz" package.id;
  check (list string) "the package declares the author and grade outputs"
    ["author"; "grade"]
    (List.sort String.compare
       (List.map (fun (output : Lane_addon_types.exact_output) -> output.name) package.exact_outputs));
  check bool "the package asks the operator" true package.operator_asks;
  check bool "the quiz log lives on persistent state" true (package.state_storage = Lane_addon_types.Persistent);
  check (option string) "compose and export arrive through lane_act" (Some "lane_act") package.action_tool;
  check int "the example grants a Board and a repository" 2
    (List.length (unwrap (Lane_addon_records.grants ~operator_owned:true loaded.binding)));
  with_directory (fun _root _packages directory ->
    let path = Filename.concat directory "quiz.toml" in
    let manifest = Unix.realpath (repo_file "addons/operator-quiz/lane.toml") in
    let declaration binding = write path (Printf.sprintf {|id = "quiz"
run_id = "quiz"
manifest_path = %S

[binding]
sources = []
language = "ko"
%s
[[binding.records]]
source_id = "board"
kind = "board"
visibilities = ["public"]
|} manifest binding) in
    declaration "timezone = \"Asia/Seoul\"\n";
    ignore (unwrap (load_declaration ~path));
    declaration "timezone = \"Asia/Seoul\"\n\n[[binding.records]]\nsource_id = \"wiki\"\nkind = \"wiki\"\n\n\
                 [[binding.records]]\nsource_id = \"prs\"\nkind = \"github_pulls\"\nrepository_id = \"masc\"\n";
    check int "the binding also takes wiki and github_pulls grants" 3
      (List.length (unwrap (Lane_addon_records.grants ~operator_owned:true (unwrap (load_declaration ~path)).binding)));
    (* The binding schema is two alternatives, and the host's validator names
       no member of an alternative: a binding that fits neither is refused
       with this one message, whichever member is wrong (#52319).
       docs/guides/operator-quiz.md quotes it and the other messages below. *)
    let unmatched = "lane binding must match exactly one schema alternative" in
    declaration "";
    check_refusal "a binding without a time zone is refused before install" path unmatched;
    declaration "timezone = \"Asia/Seoul\"\nwindow = 3\n";
    check_refusal "a binding key the package does not read is refused" path unmatched;
    (* since says where a quiz that follows a lesson reads a record source
       from until a session that asked has left a cursor on that source (RFC
       operator-quiz-follows-lesson §3.8). *)
    declaration "timezone = \"Asia/Seoul\"\nsince = 1794441600\n";
    check_refusal "a quiz on its own refuses since" path unmatched;
    (* Before the schema the host reads the TOML, turns the binding into JSON
       and checks the shape of each source: a declaration wrong there is
       refused with that check's message. *)
    declaration "timezone = \"Asia/Seoul\"\nsince = 1794441600\n\n[[binding.sources]]\nsource_id = \"lesson\"\n\
                 kind = \"lane_output\"\ninstallation_id = \"operator-lesson\"\noutput_id = \"scenes\"\n\
                 selection = \"latest_completed\"\n";
    check_refusal "sources = [] left beside [[binding.sources]] does not read as TOML" path
      "table [binding.sources] is duplicated by an array of tables [[binding.sources]]";
    write path (Printf.sprintf {|id = "quiz"
run_id = "quiz"
manifest_path = %S

[binding]
sources = "lesson"
language = "ko"
timezone = "Asia/Seoul"

[[binding.records]]
source_id = "board"
kind = "board"
visibilities = ["public"]
|} manifest);
    check_refusal "sources that is not an array is refused" path
      "binding.sources requires an array of observation sources";
    write path (Printf.sprintf {|id = "quiz"
run_id = "quiz"
manifest_path = %S

[binding]
language = "ko"
timezone = "Asia/Seoul"
since = 1794441600

[[binding.records]]
source_id = "board"
kind = "board"
visibilities = ["public"]
|} manifest);
    check_refusal "a binding whose sources = [] was deleted with no source in its place is refused" path
      "binding.sources requires an array of observation sources";
    (* The TOML reader words the same mistake by where the lines are: with
       the lesson source after two record grants it raises an internal error
       of its own. The guide says so. *)
    write path (Printf.sprintf {|id = "quiz"
run_id = "quiz"
manifest_path = %S

[binding]
sources = []
language = "ko"
timezone = "Asia/Seoul"
since = 1794441600

[[binding.records]]
source_id = "board"
kind = "board"
visibilities = ["public"]

[[binding.records]]
source_id = "wiki"
kind = "wiki"

[[binding.sources]]
source_id = "lesson"
kind = "lane_output"
installation_id = "operator-lesson"
output_id = "scenes"
selection = "latest_completed"
|} manifest);
    check_refusal "sources = [] left with the lesson source after two record grants is the reader's own error" path
      "otoml internal error";
    let following ?(since = "since = 1794441600\n") ?(selection = "selection = \"latest_completed\"\n") ?(more = "")
        output = write path (Printf.sprintf {|id = "quiz"
run_id = "quiz"
manifest_path = %S

[binding]
language = "ko"
timezone = "Asia/Seoul"
%s
[[binding.sources]]
source_id = "lesson"
kind = "lane_output"
installation_id = "operator-lesson"
output_id = %S
%s%s
[[binding.records]]
source_id = "board"
kind = "board"
visibilities = ["public"]
|} manifest since output selection more) in
    following "scenes";
    ignore (unwrap (load_declaration ~path));
    (* The worker takes zero and a fraction of a second, so the host does. *)
    following ~since:"since = 0\n" "scenes";
    ignore (unwrap (load_declaration ~path));
    following ~since:"since = 1794441600.5\n" "scenes";
    ignore (unwrap (load_declaration ~path));
    following ~since:"" "scenes";
    check_refusal "a quiz that follows a lesson without since is refused" path unmatched;
    following ~since:"since = \"yesterday\"\n" "scenes";
    check_refusal "a since that is not a number is refused" path unmatched;
    following ~since:"since = -1\n" "scenes";
    check_refusal "a since before 1970 is refused" path unmatched;
    following ~since:"since = 2026-11-12\n" "scenes";
    check_refusal "a since written as a TOML date is refused before the schema" path
      "binding.since: TOML date/time values are unsupported; use an explicit string";
    following ~since:"since = nan\n" "scenes";
    check_refusal "a since that is not finite is refused before the schema" path
      "binding.since: non-finite numbers are not supported";
    following "lesson";
    check_refusal "a source that is not a lesson's scenes output is refused" path unmatched;
    following ~more:"language = \"ko\"\n" "scenes";
    check_refusal "a binding key written under the lesson source is refused as a field of that source" path
      "lane_output contains duplicate or unknown fields";
    following ~selection:"" "scenes";
    check_refusal "a lesson source without its selection is refused" path
      "lane_output selection must be latest_completed";
    (* Then each record grant (#52373). The schema asks a grant for source_id
       and kind only, so before the host read grants here a Board grant
       without visibilities was saved and refused only when its worker was
       attached. *)
    let grant fields = declaration ("timezone = \"Asia/Seoul\"\n\n[[binding.records]]\n" ^ fields) in
    grant "source_id = \"notes\"\nkind = \"board\"\n";
    check_refusal "a Board grant without visibilities is refused" path
      "binding.records: visibilities requires a non-empty array";
    grant "source_id = \"wiki\"\nkind = \"wiki\"\npaths = [\"docs/\"]\n";
    check_refusal "a wiki grant with paths is refused" path
      "binding.records: a record grant has no key paths";
    grant "source_id = \"board\"\nkind = \"wiki\"\n";
    check_refusal "a second grant under a granted source_id is refused" path
      "binding.records: records names the same source_id twice";
    following ~more:"\n[[binding.sources]]\nsource_id = \"lesson-2\"\nkind = \"lane_output\"\n\
                     installation_id = \"operator-lesson-2\"\noutput_id = \"scenes\"\n\
                     selection = \"latest_completed\"\n" "scenes";
    check_error "a second lesson source is refused" path;
    (* The example, changed as its comment says: without sources = [], and with
       since and the lesson source uncommented. Every uncommented key has to
       land in [binding] or in the source, not in a table after it. *)
    let example = In_channel.with_open_bin
        (repo_file "docs/examples/lane-addons/operator-quiz.toml") In_channel.input_all in
    let _, lines = List.fold_left (fun (inside, kept) line ->
        let starts prefix = String.starts_with ~prefix line in
        let inside = inside || starts "# since = " in
        let kept =
          if line = "sources = []" then kept
          else if starts "manifest_path = " then Printf.sprintf "manifest_path = %S" manifest :: kept
          else if inside && starts "# " then String.sub line 2 (String.length line - 2) :: kept
          else line :: kept in
        (inside && not (starts "# selection = "), kept))
        (false, []) (String.split_on_char '\n' example) in
    write path (String.concat "\n" (List.rev lines));
    let binding = (unwrap (load_declaration ~path)).binding in
    check bool "the example bound to a lesson keeps its time zone and since" true
      Yojson.Safe.Util.(member "timezone" binding = `String "Asia/Seoul" && member "since" binding <> `Null);
    check int "and reads the lesson's scenes output" 1
      (List.length (Yojson.Safe.Util.(member "sources" binding |> to_list))))

(* The shipped operator lesson: the example declaration loads with the
   package's own manifest, and the binding contract refuses a binding without
   the time the first lesson reads from. *)
let shipped_operator_lesson_declaration_loads () =
  let loaded = unwrap (load_declaration ~path:(repo_file "docs/examples/lane-addons/operator-lesson.toml")) in
  let package = loaded.package in
  check string "the declaration names the package" "operator-lesson" package.id;
  check (list string) "the package declares the outline and scene outputs"
    ["outline"; "scene"]
    (List.sort String.compare
       (List.map (fun (output : Lane_addon_types.exact_output) -> output.name) package.exact_outputs));
  check bool "the package does not ask the operator" false package.operator_asks;
  check bool "the scenes port selects the scene lane alone" true
    (List.assoc_opt "scenes" package.outputs = Some (Lane_addon_types.Selected_lanes ["lesson/scenes"]));
  check bool "the lesson log lives on persistent state" true (package.state_storage = Lane_addon_types.Persistent);
  check (option string) "compose and export arrive through lane_act" (Some "lane_act") package.action_tool;
  check int "the example grants a Board and a repository" 2
    (List.length (unwrap (Lane_addon_records.grants ~operator_owned:true loaded.binding)));
  with_directory (fun _root _packages directory ->
    let path = Filename.concat directory "lesson.toml" in
    let manifest = Unix.realpath (repo_file "addons/operator-lesson/lane.toml") in
    let declaration binding = write path (Printf.sprintf {|id = "lesson"
run_id = "lesson"
manifest_path = %S

[binding]
sources = []
language = "ko"
%s
[[binding.records]]
source_id = "board"
kind = "board"
visibilities = ["public"]
|} manifest binding) in
    declaration "since = 1794441600\n";
    ignore (unwrap (load_declaration ~path));
    declaration "";
    check_error "a binding without since is refused before install" path;
    declaration "since = \"yesterday\"\n";
    check_error "a since that is not a number is refused" path;
    declaration "since = 1794441600\ntimezone = \"Asia/Seoul\"\n";
    check_error "a binding key the package does not read is refused" path)

(* The operator quiz worker itself, read with the host's own decoders: the
   action schema the worker start checks, the observation packet, and the
   host request listing after a compose. *)
let operator_quiz_worker_speaks_the_host_contract () = with_directory (fun _root _packages directory ->
  (* One JSON-RPC message per line, so no literal here spans two lines. *)
  let binding = {|{"sources": [], "language": "ko", "timezone": "Asia/Seoul", |}
    ^ {|"records": [{"source_id": "board", "kind": "board", "visibilities": ["public"]}]}|} in
  let context = {|{"instance_id": "quiz-1", "incarnation": "quiz-1"}|} in
  let calls = [
    {|"initialize", "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "t", "version": "1"}}|};
    {|"tools/list", "params": {}|};
    Printf.sprintf {|"tools/call", "params": {"name": "lane_observe", "arguments": {"context": %s, "binding": %s, "sources": []}}|} context binding;
    Printf.sprintf {|"tools/call", "params": {"name": "lane_act", "arguments": {"context": %s, "request_id": "act-1", "action": {"kind": "compose", "questions": 2}}}|} context;
    {|"tools/call", "params": {"name": "lane_host_requests", "arguments": {}}|}] in
  let input = String.concat "" (List.mapi (fun index call ->
    Printf.sprintf {|{"jsonrpc": "2.0", "id": %d, "method": %s}|} (index + 1) call ^ "\n") calls) in
  let state = Filename.concat directory "state" in
  let output, input_channel = Unix.open_process_args "python3"
    [|"python3"; repo_file "addons/operator-quiz/server.py"; "--state"; state|] in
  output_string input_channel input;
  close_out input_channel;
  let lines = In_channel.input_lines output in
  (match Unix.close_process (output, input_channel) with
   | Unix.WEXITED 0 -> ()
   | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> fail "the quiz worker did not exit cleanly");
  let result position = Yojson.Safe.Util.(List.nth lines position |> Yojson.Safe.from_string |> member "result") in
  let structured position = Yojson.Safe.Util.member "structuredContent" (result position) in
  let tools = Yojson.Safe.Util.(result 1 |> member "tools" |> to_list) in
  let tool name = List.find (fun tool -> Yojson.Safe.Util.(member "name" tool) = `String name) tools in
  check int "the worker advertises its four tools" 4 (List.length tools);
  let schema = Yojson.Safe.Util.member "inputSchema" (tool "lane_act") in
  ignore (unwrap (Lane_addon_action.validate_schema schema));
  (* Each kind is its own closed alternative, so the host refuses a member
     another kind uses before the worker sees the action. *)
  let send action = Lane_addon_action.validate ~schema ~name:"lane_act"
    (`Assoc [ "context", Yojson.Safe.from_string context; "request_id", `String "act-2";
              "action", Yojson.Safe.from_string action ]) in
  List.iter (fun (label, action) -> check bool label true (Result.is_ok (send action)))
    [ "a compose with a count", {|{"kind":"compose","questions":2}|};
      "a dispute with its three members", {|{"kind":"dispute","ask_id":"a","question_id":"q1","note":"n"}|};
      "an export alone", {|{"kind":"export"}|} ];
  List.iter (fun (label, action) -> check bool label true (Result.is_error (send action)))
    [ "a dispute that names questions",
      {|{"kind":"dispute","ask_id":"a","question_id":"q1","note":"n","questions":1}|};
      "a compose without a count", {|{"kind":"compose"}|};
      "a dispute without a note", {|{"kind":"dispute","ask_id":"a","question_id":"q1"}|} ];
  (* The shipped dispute row action is offered on the Dispute alternative of
     the schema this worker advertises, and leaves only the note. *)
  let package = (unwrap (load_declaration ~path:(repo_file "docs/examples/lane-addons/operator-quiz.toml"))).package in
  (match package.action_tool, package.presentation.Lane_addon_presentation.actions with
   | Some tool_name, [ action ] ->
       (match Lane_addon_row_action.judge ~tool_name ~tool_schema:schema action with
        | Lane_addon_row_action.Offered
            { branch = Some 1; human = [ { Lane_addon_row_action.name = "note"; required = true } ] } -> ()
        | Lane_addon_row_action.(Offered _ | Refused _) ->
            fail "the dispute row action is offered on the Dispute alternative and leaves the note")
   | (Some _ | None), _ -> fail "the quiz declares one row action and its action tool");
  ignore (unwrap (Lane_addon_packet.decode (structured 2)));
  check string "compose is confirmed" "confirmed" Yojson.Safe.Util.(structured 3 |> member "status" |> to_string);
  (match unwrap (Lane_addon_host_request.listing_of_json (structured 4)) with
   (* No session has asked yet, so the first read starts at the time the
      quiz began, not at the start of the Board (#44537). *)
   | [Lane_addon_host_request.Read_records {source_id = "board"; start = Lane_addon_records.Since _; _}] -> ()
   | _ -> fail "the first request of a session reads the granted Board since the quiz began"))

let tool_hooks_are_selected_and_revisioned () = with_directory (fun _root packages directory ->
  let manifest = install_package packages in
  let path = Filename.concat directory "hooks.toml" in
  write path (declaration msx_binding);
  let initial = unwrap (load_declaration ~path) in
  check bool "old package has no hooks" true (initial.package.tool_hooks = []);
  check bool "no hook key changes old package identity" true
    (Yojson.Safe.Util.member "tool_hooks" (Lane_addon_types.package_to_json initial.package) = `Null);
  write manifest (package () ^ "\n[world.tools]\nexport = [\"machine_step\"]\nhooks = [\"validate_output\"]\n");
  let default = unwrap (load_declaration ~path) in
  check bool "package selects output validation" true
    (default.package.tool_hooks = [Lane_addon_types.Validate_output]);
  write path (declaration ~extra:"tool_hooks = []" msx_binding);
  let off = unwrap (load_declaration ~path) in
  check bool "installation can turn optional hooks off" true (off.package.tool_hooks = []);
  check bool "hook change replaces the worker identity" true (off.revision <> default.revision);
  write path (declaration ~extra:"tool_hooks = [\"validate_input\"]" msx_binding);
  let input = unwrap (load_declaration ~path) in
  check bool "input can be selected independently" true
    (input.package.tool_hooks = [Lane_addon_types.Validate_input]);
  List.iter (fun extra ->
    write path (declaration ~extra msx_binding);
    check_error "unknown, duplicate or malformed hook selection is refused" path)
    ["tool_hooks = [\"unknown\"]"; "tool_hooks = [\"validate_input\", \"validate_input\"]";
     "tool_hooks = true"; "tool_hooks = [1]"])

let model_access_is_explicit_and_revisioned () = with_directory (fun _root packages directory ->
  let manifest = install_package packages in
  let path = Filename.concat directory "model.toml" in
  write path (declaration msx_binding);
  let initial = unwrap (load_declaration ~path) in
  check bool "omitted model access grants no sampling" true
    (initial.package.model_access=Lane_addon_types.Model_disabled);
  write manifest (package () ^ "\n[interface]\nmodel_access = \"host_sampling\"\n");
  let enabled = unwrap (load_declaration ~path) in
  check bool "model access is a typed explicit package requirement" true
    (enabled.package.model_access=Lane_addon_types.Host_sampling);
  check bool "model access changes the applied configuration identity" false
    (initial.revision=enabled.revision);
  write manifest (package () ^ "\n[interface]\nmodel_access = \"disabled\"\n");
  let disabled = unwrap (load_declaration ~path) in
  check bool "explicitly disabled and omitted have identical semantics" true
    (initial.revision=disabled.revision);
  List.iter (fun value ->
    write manifest (package () ^ "\n[interface]\nmodel_access = " ^ value ^ "\n");
    check_error "unknown or untyped model access is rejected" path) ["\"auto\"";"true"])

let operator_asks_are_a_package_declaration () = with_directory (fun _root packages directory ->
  let manifest = install_package packages in
  let path = Filename.concat directory "quiz.toml" in
  write path (declaration msx_binding);
  let initial = unwrap (load_declaration ~path) in
  check bool "a package without the table does not ask" false initial.package.operator_asks;
  check bool "and its package value carries no operator_asks key" true
    (Yojson.Safe.Util.member "operator_asks" (Lane_addon_types.package_to_json initial.package) = `Null);
  write manifest (package () ^ "\n[world.asks]\noperator = true\n");
  let asking = unwrap (load_declaration ~path) in
  check bool "operator = true lets the package ask" true asking.package.operator_asks;
  check bool "and changes the configuration identity" false (initial.revision = asking.revision);
  List.iter (fun table ->
    write manifest (package () ^ "\n[world.asks]\n" ^ table);
    check bool ("world.asks refuses " ^ table) true (Result.is_error (load_declaration ~path)))
    [ "operator = \"yes\"\n"; "operator = true\nkeeper = true\n" ])

(* RFC librarian-read-waits-and-shrinks-no-further-than-the-refusal-says 3.1. *)
let host_request_pages_are_a_package_declaration () = with_directory (fun _root packages directory ->
  let manifest = install_package packages in
  let path = Filename.concat directory "quiz.toml" in
  write path (declaration msx_binding);
  let with_world world = write manifest (package () ^ "\n[world]\n" ^ world) in
  with_world "[world.asks]\noperator = true\n";
  let initial = unwrap (load_declaration ~path) in
  check bool "a package without the key answers once" true
    (initial.package.host_request_listing = Lane_addon_types.One_answer);
  check bool "and its package value carries no host_request_pages key" true
    (Yojson.Safe.Util.member "host_request_pages" (Lane_addon_types.package_to_json initial.package) = `Null);
  with_world "host_request_pages = true\n[world.asks]\noperator = true\n";
  let paged = unwrap (load_declaration ~path) in
  check bool "host_request_pages = true answers in pages" true
    (paged.package.host_request_listing = Lane_addon_types.Pages);
  check bool "and changes the configuration identity" false (initial.revision = paged.revision);
  List.iter (fun (label, world) ->
    with_world world;
    check bool label true (Result.is_error (load_declaration ~path)))
    [ "a value that is not a boolean", "host_request_pages = \"yes\"\n[world.asks]\noperator = true\n"
    ; "pages without a host request", "host_request_pages = true\n" ])

let exact_protocol_is_the_one_this_server_speaks () = with_directory (fun _root packages directory ->
  let manifest = install_package packages in
  let path = Filename.concat directory "quiz.toml" in
  write path (declaration msx_binding);
  write (Filename.concat packages "answer.json")
    {|{"type":"object","properties":{"ok":{"type":"boolean"}},"required":["ok"],"additionalProperties":false}|};
  let with_world world = write manifest (package () ^ "\n[world]\n" ^ world) in
  let output = "[world.exact_outputs.answer]\nschema = \"answer.json\"\n" in
  let server = Lane_addon_types.exact_protocol in
  with_world (Printf.sprintf "exact_protocol = %d\n%s" server output);
  let declared = unwrap (load_declaration ~path) in
  check int "a package written for this server's protocol declares its exact output" 1
    (List.length declared.package.exact_outputs);
  List.iter (fun (label, world, words) ->
    with_world world;
    match load_declaration ~path with
    | Ok _ -> failf "%s was accepted" label
    | Error message ->
        List.iter (fun word -> check bool (label ^ " is refused naming " ^ word) true (contains message word)) words)
    [ "exact outputs without a protocol", output,
      [ "world.exact_protocol is missing"; Printf.sprintf "Exact protocol %d" server ]
    ; "another protocol", Printf.sprintf "exact_protocol = %d\n%s" (server + 1) output,
      [ Printf.sprintf "world.exact_protocol is %d" (server + 1); Printf.sprintf "Exact protocol %d" server ]
    ; "a protocol without exact outputs", Printf.sprintf "exact_protocol = %d\n" server,
      [ "world.exact_protocol requires exact_outputs" ]
    ; "a protocol that is not an integer", Printf.sprintf "exact_protocol = \"%d\"\n%s" server output,
      [ "world.exact_protocol requires an integer" ] ])

(* Writes this binary's copy of [id] where a [package = "<name>"]
   declaration looks for it, and answers that folder. *)
let place_carried packages id =
  let folder = unwrap (Lane_addon_carried.folder ~packages id) in
  List.iter (fun (file : Lane_addon_carried.file) ->
      let path = Filename.concat folder file.path in
      Fs_compat.mkdir_p (Filename.dirname path);
      write path file.contents)
    (Lane_addon_carried.package_files id);
  folder

let carried_packages_are_complete_manifests () = with_directory (fun _root packages _directory ->
  check (list string) "every carried image copies the same two shared modules"
    ["exact_worker.py"; "protocol.py"]
    (List.map (fun (file : Lane_addon_carried.file) -> file.path) Lane_addon_carried.shared_files);
  List.iter (fun id ->
      let name = Lane_addon_carried.name id in
      check bool (name ^ " is found by its own name") true (Lane_addon_carried.of_name name = Some id);
      let revision = unwrap (Lane_addon_carried.revision id) in
      let folder = place_carried packages id in
      check string (name ^ " is installed under its name and revision")
        (Filename.concat packages (name ^ "-" ^ revision)) folder;
      let manifest = unwrap (Lane_addon_carried.installed_manifest ~packages id
        |> Result.map_error (Lane_addon_carried.installation_error_to_string id)) in
      match Lane_addon_manifest.load ~path:manifest with
      | Error error -> fail (name ^ ": " ^ Lane_addon_manifest.error_to_string error)
      | Ok package ->
          check string (name ^ " declares its own id") name package.id;
          check string (name ^ " declares the revision its folder names") revision package.revision;
          check bool (name ^ " declares exact outputs") true (package.exact_outputs <> []))
    Lane_addon_carried.all)

let a_declaration_names_a_carried_package () = with_directory (fun _root packages directory ->
  let path = Filename.concat directory "judge.toml" in
  let declare keys = write path (Printf.sprintf "id = \"judge\"\nrun_id = \"memory\"\n%s[binding]\nsources = []\n" keys) in
  let refused label words =
    match load_declaration ~path with
    | Ok _ -> failf "%s was accepted" label
    | Error message ->
        List.iter (fun word -> check bool (label ^ " is refused naming " ^ word) true (contains message word)) words in
  let carried = Lane_addon_carried.Hitl_auto_judge in
  let folder = unwrap (Lane_addon_carried.folder ~packages carried) in
  declare "package = \"hitl-auto-judge\"\n";
  refused "a carried package that is not installed" ["is not installed"; folder; "masc exact-addon-setup"];
  ignore (place_carried packages carried);
  let declaration = unwrap (load_declaration ~path) in
  check string "the declaration resolves to the installed folder"
    (Unix.realpath (Filename.concat folder "lane.toml")) declaration.manifest_path;
  check string "and attaches the carried package" "hitl-auto-judge" declaration.package.id;
  check bool "the declaration records that it names the carried package" true
    (declaration.package_source = Config.Carried carried);
  declare (Printf.sprintf "manifest_path = %S\n" (Filename.concat folder "lane.toml"));
  let by_path = unwrap (load_declaration ~path) in
  check bool "a manifest_path to the same folder records the path" true
    (by_path.package_source = Config.Manifest_path);
  check string "and reads the same manifest" declaration.manifest_path by_path.manifest_path;
  let image_label (d : Config.declaration) = match d.package.execution with
    | Lane_addon_types.Container container -> container.image_label
    | Lane_addon_types.Host_process _ -> failf "%s does not run in a container" d.id in
  check bool "the carried declaration requires this server's image digest" true
    (image_label declaration = Some { Lane_addon_types.label_key = Lane_addon_carried.image_label;
                                      label_value = Lane_addon_carried.image_digest carried });
  check bool "the manifest_path declaration requires no image label" true (image_label by_path = None);
  let names_image_label (d : Config.declaration) =
    match Lane_addon_types.execution_package_json d.package with
    | `Assoc fields -> List.mem_assoc "image_label" fields
    | _ -> failf "%s package JSON is not an object" d.id in
  check bool "the carried requirement is a worker input of the revision" true (names_image_label declaration);
  check bool "a package without it keeps the revision it had" false (names_image_label by_path);
  check bool "so the two declarations have different revisions" false
    (String.equal declaration.revision by_path.revision);
  declare "package = \"hitl-auto-judge\"\n";
  let server = Filename.concat folder "server.py" in
  write server "# another worker\n";
  refused "a folder whose worker has other bytes" ["server.py has other bytes"; folder];
  ignore (place_carried packages carried);
  write (Filename.concat folder "notes.txt") "operator notes";
  refused "a folder with a file the package does not carry" ["unexpected notes.txt"];
  Sys.remove (Filename.concat folder "notes.txt");
  Sys.remove (Filename.concat folder "schemas/judgment.json");
  refused "a folder missing a carried file" ["missing schemas/judgment.json"];
  ignore (place_carried packages carried);
  Sys.remove server;
  Unix.symlink (Filename.concat directory "judge.toml") server;
  refused "a folder holding a symbolic link" ["server.py is not a regular file or directory"];
  Sys.remove server;
  ignore (place_carried packages carried);
  check bool "the restored folder is accepted again" true (Result.is_ok (load_declaration ~path));
  List.iter (fun (label, keys, words) -> declare keys; refused label words)
    [ "both package and manifest_path",
      "package = \"hitl-auto-judge\"\nmanifest_path = \"../packages/lane.toml\"\n", ["both package and manifest_path"]
    ; "neither package nor manifest_path", "", ["requires package or manifest_path"]
    ; "a package this server does not carry", "package = \"browser-ego\"\n",
      ["\"browser-ego\" is not one this server carries"; "hitl-auto-judge"]
    ; "a package that is not a name", "package = 1\n", ["package requires"] ])

let exact_outputs_are_package_schemas () = with_directory (fun root packages directory ->
  let manifest = install_package packages in
  let path = Filename.concat directory "quiz.toml" in
  write path (declaration msx_binding);
  let schemas = Filename.concat packages "schemas" in
  Unix.mkdir schemas 0o700;
  let author = {|{"type":"object","properties":{"questions":{"type":"array","items":{"type":"string"}}},"required":["questions"],"additionalProperties":false}|} in
  write (Filename.concat schemas "author.json") author;
  write (Filename.concat schemas "grade.json") {|{"type":"object","properties":{"verdict":{"type":"string","enum":["correct","incorrect"]}},"additionalProperties":false}|};
  let with_outputs tables = write manifest (package () ^ "\n[world]\nexact_protocol = 1\n" ^ tables) in
  let initial = unwrap (load_declaration ~path) in
  check int "a package without the table declares no exact output" 0
    (List.length initial.package.exact_outputs);
  check bool "and its package value carries no exact_outputs key, so its revision is unchanged" true
    (Yojson.Safe.Util.member "exact_outputs" (Lane_addon_types.package_to_json initial.package) = `Null);
  with_outputs {|[world.exact_outputs.grade]
schema = "schemas/grade.json"
[world.exact_outputs.author]
schema = "schemas/author.json"
|};
  let declared = unwrap (load_declaration ~path) in
  check (list string) "outputs are listed in name order" ["author"; "grade"]
    (List.map (fun (output : Lane_addon_types.exact_output) -> output.name) declared.package.exact_outputs);
  check bool "the schema is the file's JSON" true
    ((List.hd declared.package.exact_outputs).schema = Yojson.Safe.from_string author);
  check bool "declaring exact outputs changes the configuration identity" false
    (initial.revision = declared.revision);
  write (Filename.concat schemas "grade.json") {|{"type":"object","properties":{"verdict":{"type":"string"}},"additionalProperties":false}|};
  let edited = unwrap (load_declaration ~path) in
  check bool "editing a schema file changes the configuration identity" false
    (declared.revision = edited.revision);
  write manifest (package ());
  check string "removing the table returns to the first identity" initial.revision
    (unwrap (load_declaration ~path)).revision;
  write (Filename.concat schemas "text.json") {|{"type":"string"}|};
  write (Filename.concat schemas "pattern.json") {|{"type":"object","patternProperties":{"^a":{"type":"string"}},"additionalProperties":false}|};
  write (Filename.concat schemas "broken.json") {|{"type":"object",|};
  write (Filename.concat root "outside.json") author;
  Unix.symlink (Filename.concat root "outside.json") (Filename.concat schemas "escape.json");
  List.iter (fun (label, tables) ->
    with_outputs tables;
    match load_declaration ~path with
    | Ok _ -> failf "%s was accepted" label
    | Error message ->
        check bool (label ^ " is refused by the exact_outputs reader") true
          (contains message "world.exact_outputs"))
    [ "a directory", "[world.exact_outputs.author]\nschema = \"schemas\"\n";
      "an upper-case name", "[world.exact_outputs.Author]\nschema = \"schemas/author.json\"\n";
      "a name starting with a digit", "[world.exact_outputs.2nd]\nschema = \"schemas/author.json\"\n";
      "a key beside schema", "[world.exact_outputs.author]\nschema = \"schemas/author.json\"\nmodel = \"x\"\n";
      "no schema", "[world.exact_outputs.author]\n";
      "non-boolean schema grant", "[world.exact_outputs.author]\nschema = \"schemas/author.json\"\nrequest_schema = \"true\"\n";
      "an empty table", "[world.exact_outputs]\n";
      "a parent path", "[world.exact_outputs.author]\nschema = \"../outside.json\"\n";
      "an absolute path", Printf.sprintf "[world.exact_outputs.author]\nschema = %S\n" (Filename.concat root "outside.json");
      "a missing file", "[world.exact_outputs.author]\nschema = \"schemas/absent.json\"\n";
      "a symlink out of the package", "[world.exact_outputs.author]\nschema = \"schemas/escape.json\"\n";
      "invalid JSON", "[world.exact_outputs.author]\nschema = \"schemas/broken.json\"\n";
      "a schema that is not an object", "[world.exact_outputs.author]\nschema = \"schemas/text.json\"\n";
      "an unsupported keyword", "[world.exact_outputs.author]\nschema = \"schemas/pattern.json\"\n" ])

let exact_outputs_are_selected_independently () = with_directory (fun _root packages directory ->
  let manifest = install_package packages in
  let schema = {|{"type":"object","properties":{"value":{"type":"string"}},"required":["value"],"additionalProperties":false}|} in
  write (Filename.concat packages "answer.json") schema;
  write manifest (package () ^ {|
[world]
exact_protocol = 1
[world.tools]
export = []
hooks = ["validate_input", "validate_output"]
[world.exact_outputs.plan]
schema = "answer.json"
[world.exact_outputs.extract]
schema = "answer.json"
|});
  let path = Filename.concat directory "browser.toml" in
  let install extra =
    write path (declaration ~extra msx_binding);
    load_declaration ~path in
  let names (value:Config.declaration) = List.map
      (fun (output:Lane_addon_types.exact_output) -> output.name) value.package.exact_outputs in
  let default = unwrap (install "") in
  check bool "a package grants only its fixed schema by default" true
    (List.for_all (fun (output:Lane_addon_types.exact_output) -> output.request_schema=Package_schema_only)
      default.package.exact_outputs);
  check (list string) "omission keeps package outputs" ["extract";"plan"] (names default);
  let all = unwrap (install {|exact_outputs = ["plan", "extract"]|}) in
  check string "explicit full selection has the same effective identity" default.revision all.revision;
  check (list string) "selection order does not replace package order" ["extract";"plan"] (names all);
  let selected = unwrap (install {|exact_outputs = ["plan"]|}) in
  check (list string) "one named model output can be enabled" ["plan"] (names selected);
  check bool "selection retains the package schema" true
    ((List.hd selected.package.exact_outputs).schema=Yojson.Safe.from_string schema);
  check bool "changing model selection changes worker inputs" true (selected.revision<>default.revision);
  check bool "model selection leaves tool hooks alone" true (selected.package.tool_hooks=default.package.tool_hooks);
  let off = unwrap (install {|exact_outputs = []|}) in
  check (list string) "empty selection disables all exact outputs" [] (names off);
  check bool "disabling model outputs keeps both contract hooks" true
    (off.package.tool_hooks=[Validate_input;Validate_output]);
  check bool "disabling outputs changes worker identity" true (off.revision<>default.revision);
  let unchecked = unwrap (install {|exact_outputs = ["plan"]
tool_hooks = []|}) in
  check (list string) "model output remains selected without contract hooks" ["plan"] (names unchecked);
  check bool "tool validation can be disabled independently" true (unchecked.package.tool_hooks=[]);
  let all_off = unwrap (install {|exact_outputs = []
tool_hooks = []|}) in
  check bool "all optional middleware can be disabled together" true
    (all_off.package.exact_outputs=[] && all_off.package.tool_hooks=[]);
  let restored = unwrap (install "") in
  check string "restoring package defaults restores effective identity" default.revision restored.revision;
  List.iter (fun selection ->
    match install ("exact_outputs = " ^ selection) with
    | Ok _ -> failf "invalid exact-output selection accepted: %s" selection
    | Error detail -> check bool "selection failure identifies exact output policy" true (contains detail "exact output" || contains detail "exact_outputs"))
    [ {|["unknown"]|}; {|["plan", "plan"]|}; {|["plan", 1]|}; {|[""]|};
      {|[" plan"]|}; "true"; {|"plan"|}; "{}" ];
  write manifest (package () ^ {|
[world]
exact_protocol = 1
[world.exact_outputs.plan]
schema = "answer.json"
[world.exact_outputs.extract]
schema = "answer.json"
request_schema = true
|});
  let granted=unwrap (install "") in
  check bool "a schema grant changes effective worker identity" true (granted.revision<>default.revision);
  let selected=unwrap (install {|exact_outputs = ["extract"]|}) in
  check bool "selection preserves the package's schema authority" true
    ((List.hd selected.package.exact_outputs).request_schema=Consumer_request_schema);
  write manifest (package ());
  check bool "selection cannot invent a package output" true
    (Result.is_error (install {|exact_outputs = ["plan"]|}));
  let absent = unwrap (install "") in
  let empty = unwrap (install {|exact_outputs = []|}) in
  check string "empty override without declarations keeps effective identity" absent.revision empty.revision)

let assembled_fusion_declarations () =
  List.iter (fun name ->
    let loaded = unwrap (load_declaration ~path:(repo_file
      ("docs/examples/lane-addons/fusion-compute/" ^ name ^ ".toml"))) in
    check string "assembled workers belong to one host run" "assembled-fusion" loaded.run_id;
    let expected = if name="report" then Lane_addon_types.Model_disabled
      else Lane_addon_types.Host_sampling in
    check bool "computation has explicit model access; reporting has none" true
      (loaded.package.model_access=expected);
    check bool "the shipped installation has an enforceable binding schema" true
      (Option.is_some loaded.package.binding_schema)) ["panel-a";"panel-b";"judge";"report"]

let alternative_probes_do_not_observe_tool_calls () =
  let object_schema fields = `Assoc ["type",`String "object";
    "properties",`Assoc fields;"required",`List (List.map (fun (key,_) -> `String key) fields);
    "additionalProperties",`Bool false] in
  let branch operation = object_schema [
    "operation",`Assoc ["type",`String "string";"const",`String operation];
    "count",`Assoc ["type",`String "integer";"minimum",`Int 1;"maximum",`Int 2]] in
  let read=branch "read" and submit=branch "submit" in
  let schema branches = object_schema ["payload",`Assoc ["type",`String "array";
    "items",`Assoc ["type",`String "object";"oneOf",`List branches]]] in
  let input operation count = `Assoc ["payload",`List [`Assoc [
    "operation",`String operation;"count",count]]] in
  let tool="__addon_validation_observation_boundary" in
  let contract=schema [read;submit] in
  let hooks schema =
    let definition=Mcp_protocol.Mcp_types.tool_of_yojson (`Assoc [
      "name",`String tool;"inputSchema",schema;"outputSchema",schema]) |> unwrap in
    Lane_addon_tool_hooks.prepare ~hooks:[Validate_input;Validate_output] definition |> unwrap in
  let reply value = {(Mcp_protocol.Mcp_types.tool_result_of_text "worker result") with
    is_error=Some false;structured_content=Some value} in
  let events=ref [] in
  Otel_spans.with_test_event_emitter ~enabled:true
    ~emit_event:(fun ~name ~attrs -> events := (name,attrs)::!events) (fun () ->
      let metric=Otel_metric_store.metric_tool_input_validation in
      let before=Otel_metric_store.metric_total metric in
      let log_before=(Log.Ring.bounds ()).total in
      let selected=hooks contract in
      List.iter (fun value ->
        ignore (unwrap (Lane_addon_action.validate_input ~schema:contract ~name:tool value));
        unwrap (Lane_addon_tool_hooks.before_call selected value);
        unwrap (Lane_addon_tool_hooks.after_call selected (reply value)))
        [input "read" (`Int 1);input "submit" (`Int 2)];
      List.iter (fun (label,value) ->
        check bool (label ^ " remains an input refusal") true
          (Result.is_error (Lane_addon_tool_hooks.before_call selected value));
        check bool (label ^ " remains an output refusal") true
          (Result.is_error (Lane_addon_tool_hooks.after_call selected (reply value))))
        ["zero matching alternatives",input "other" (`Int 1);
         "nested type",input "submit" (`String "1");
         "nested range",input "submit" (`Int 3);
         "closed nested object",`Assoc ["payload",`List [`Assoc [
           "operation",`String "submit";"count",`Int 1;"extra",`Bool true]]]];
      let overlapping=hooks (schema [read;submit;submit]) in
      let value=input "submit" (`Int 1) in
      check bool "two matching alternatives remain an input refusal" true
        (Result.is_error (Lane_addon_tool_hooks.before_call overlapping value));
      check bool "two matching alternatives remain an output refusal" true
        (Result.is_error (Lane_addon_tool_hooks.after_call overlapping (reply value)));
      check (float 0.) "schema probes emit no tool-validation counters" before
        (Otel_metric_store.metric_total metric);
      check int "schema probes emit no tool-validation events" 0 (List.length !events);
      check int "schema probes emit no rejection logs" log_before (Log.Ring.bounds ()).total;
      (* Real tool admission still owns one observation per validation, whether
         it accepts or refuses. It is not part of candidate branch matching. *)
      check bool "host boundary still accepts" true
        (Result.is_ok (Tool_input_validation.validate_args ~schema:contract ~name:tool
          ~args:(input "submit" (`Int 1)) ()));
      check bool "host boundary still refuses wrong types" true
        (Result.is_error (Tool_input_validation.validate_args ~schema:contract ~name:tool
          ~args:(`Assoc ["payload",`String "wrong type"]) ()));
      check (float 0.) "host boundary records two actual validations" (before +. 2.)
        (Otel_metric_store.metric_total metric);
      check (list (option string)) "only actual validations publish their outcome"
        [Some "pass";Some "fail"]
        (List.rev !events |> List.map (fun (_,attrs) ->
          match List.assoc_opt "tool.param.validation.result" attrs with
          | Some (`String value) -> Some value
          | _ -> None)))

let judge_source_schema_is_enforced () =
  let loaded = unwrap (load_declaration ~path:(repo_file
    "docs/examples/lane-addons/fusion-compute/judge.toml")) in
  let schema = Option.get loaded.package.binding_schema in
  let validate value = Lane_addon_action.validate_value ~schema ~name:"binding" value in
  check bool "shipped judge source contract is accepted" true (Result.is_ok (validate loaded.binding));
  let snapshot = `Assoc ["source_id",`String "input";"kind",`String "snapshot_file";
    "path",`String "/fixture/snapshot.json"] in
  let change role = match loaded.binding with
    | `Assoc fields -> `Assoc (("role",`String role)::("sources",`List [snapshot])::
        (List.remove_assoc "role" (List.remove_assoc "sources" fields)))
    | _ -> fail "binding must be an object" in
  check bool "judge snapshot is rejected before worker start" true (Result.is_error (validate (change "judge")));
  check bool "panel snapshot remains accepted" true (Result.is_ok (validate (change "panel")));
  with_directory (fun _root _packages declarations ->
    let path = Filename.concat declarations "role.toml" in
    let declaration role = Printf.sprintf "id = \"role-check\"\nrun_id = \"role-check\"\nmanifest_path = %S\n[binding]\nanalysis_id = \"a\"\nrole = %S\nprompt = \"compare\"\ninstructions = \"judge evidence\"\nmax_tokens = 8\nmodel_route = \"declared\"\n[[binding.sources]]\nsource_id = \"input\"\nkind = \"snapshot_file\"\npath = \"snapshot.json\"\n" loaded.manifest_path role in
    write path (declaration "judge");
    check bool "load_declaration rejects unusable judge snapshot declaration" true (Result.is_error (load_declaration ~path));
    write path (declaration "panel");
    check bool "load_declaration accepts panel snapshot declaration" true (Result.is_ok (load_declaration ~path)));
  let branch = `Assoc ["type",`String "string"] in
  let union branches = `Assoc ["type",`String "string";"oneOf",`List branches] in
  check bool "oneOf rejects overlapping alternatives" true
    (Result.is_error (Lane_addon_action.validate_value ~schema:(union [branch;branch]) ~name:"value" (`String "x")));
  check bool "oneOf rejects no matching alternative" true
    (Result.is_error (Lane_addon_action.validate_value ~schema:(union [branch]) ~name:"value" (`Int 1)));
  let unconstrained = `Assoc ["type",`String "object";"properties",`Assoc [];
    "additionalProperties",`Bool false] in
  check bool "pure union cannot silently ignore object constraints" true
    (Result.is_error (Lane_addon_action.validate_value_schema (`Assoc [
      "type",`String "object";"oneOf",`List [unconstrained];"required",`List [`String "x"]])));
  check bool "empty union is not an advertised enforceable schema" true
    (Result.is_error (Lane_addon_action.validate_value_schema (union [])))

(* One definition decides which resource declarations can run. A cpu count
   Docker cannot represent is refused when the manifest is read, not later when
   the worker is installed. *)
let resources_are_checked_where_they_are_read () = with_directory (fun _root packages _declarations ->
  let manifest cpus = Printf.sprintf {|id = "resources-probe"
revision = "fixture-1"
title = "Resources probe"
image = "fixture/worker"
command = ["worker"]
contributions = ["observe"]

[resources]
cpus = %s
memory_bytes = 67108864
pids = 16
max_reply_bytes = 4096
|} cpus in
  let load cpus =
    let path = Filename.concat packages "resources-probe.toml" in
    write path (manifest cpus);
    Lane_addon_manifest.load ~path in
  check bool "a runnable declaration loads" true (Result.is_ok (load "0.5"));
  check bool "a cpu count below one nano-CPU is refused at load" true (Result.is_error (load "1e-12"));
  check bool "a zero cpu count is refused at load" true (Result.is_error (load "0.0"));
  check bool "check_resources agrees with the manifest" true
    (Result.is_error (Lane_addon_types.check_resources
      {Lane_addon_types.cpus = 1e-12; memory_bytes = 1L; pids = Some 1; max_reply_bytes = 1})))

let runtime_selects_enforceable_resources () = with_directory (fun _root packages _directory ->
  let path = Filename.concat packages "runtime-probe.toml" in
  let load runtime cpus memory pids =
    write path (Printf.sprintf {|id = "runtime-probe"
revision = "fixture-1"
title = "Runtime probe"
runtime = %S
image = "fixture/worker"
command = ["worker"]
contributions = ["observe"]
[resources]
cpus = %s
memory_bytes = %s
%s
max_reply_bytes = 4096
|} runtime cpus memory pids);
    Lane_addon_manifest.load ~path in
  (* 200 MiB is the least Apple container creates (#52244). *)
  let apple = match load "apple_container" "1" "209715200" "" with
    | Ok package -> package | Error error -> fail (Lane_addon_manifest.error_to_string error) in
  check bool "explicit microVM runtime" true ((unwrap (Lane_addon_types.container apple)).runtime = Lane_addon_types.Apple_container);
  check bool "no imaginary PID cgroup" true ((unwrap (Lane_addon_types.container apple)).resources.pids = None);
  List.iter (fun (runtime,cpus,memory,pids) ->
    check bool "unsupported resource contract refused" true
      (Result.is_error (load runtime cpus memory pids)))
    ["apple_container","0.5","209715200","";
     "apple_container","1","209715201","";
     "apple_container","1","208666624","";
     "apple_container","1","134217728","";
     "apple_container","1","209715200","pids = 16";
     "docker","1","67108864","";
     "unknown","1","67108864",""];
  let docker = match load "docker" "0.5" "67108864" "pids = 16" with
    | Ok package -> package | Error error -> fail (Lane_addon_manifest.error_to_string error) in
  check bool "Docker serialized identity remains unchanged" true
    (Yojson.Safe.Util.member "runtime" (Lane_addon_types.package_to_json docker) = `Null))

let native_execution_has_no_container_claims () = with_directory (fun _root packages _directory ->
  let path = Filename.concat packages "native-probe.toml" in
  let load ?(image="") resources =
    write path (Printf.sprintf {|id = "native-probe"
revision = "fixture-1"
title = "Native probe"
runtime = "host_process"
%s
command = ["python3", "server.py"]
contributions = ["observe"]
[world.tools]
export = ["native_increment"]
hooks = ["validate_input", "validate_output"]
[resources]
%s
|} image resources);
    Lane_addon_manifest.load ~path in
  let native = match load "max_reply_bytes = 4096" with
    | Ok package -> package | Error error -> fail (Lane_addon_manifest.error_to_string error) in
  check bool "host execution is a distinct specification" true
    (match native.execution with Lane_addon_types.Host_process {max_reply_bytes=4096} -> true
      | Host_process _ | Container _ -> false);
  check int "shared protocol reads native envelope" 4096 (Lane_addon_types.max_reply_bytes native);
  check bool "container API cannot coerce native execution" true (Result.is_error (Lane_addon_types.container native));
  check (list string) "native exports belong to its shared contract" ["native_increment"] native.exported_tools;
  check bool "native selects both validation hooks" true
    (native.tool_hooks = [Lane_addon_types.Validate_input;Validate_output]);
  let serialized = Lane_addon_types.package_to_json native in
  check bool "native output has no image claim" true (Yojson.Safe.Util.member "image" serialized = `Null);
  check bool "native output declares only its actual envelope" true
    (Yojson.Safe.Util.member "resources" serialized = `Assoc ["max_reply_bytes",`Int 4096]);
  List.iter (fun resources -> check bool "native rejects unenforced or invalid declarations" true
    (Result.is_error (load resources)))
    ["max_reply_bytes = 4096\ncpus = 1";
     "max_reply_bytes = 4096\nmemory_bytes = 67108864";
     "max_reply_bytes = 4096\npids = 16";
     "max_reply_bytes = 4096\nother = 1";
     "max_reply_bytes = 0";"max_reply_bytes = -1";"cpus = 1"];
  check bool "native refuses an image rather than ignoring it" true
    (Result.is_error (load ~image:"image = \"unused\"" "max_reply_bytes = 4096")))

let browser_service_is_explicit () = with_directory (fun _root packages _directory ->
  let path=Filename.concat packages "browser.toml" in
  let load service extra=write path (Printf.sprintf {|id = "browser"
revision = "1"
title = "Browser"
runtime = "host_process"
service = %s
command = ["masc-browser-addon-worker"]
contributions = ["observe"]
[resources]
max_reply_bytes = 4096
%s
|} service extra);Lane_addon_manifest.load ~path in
  check bool "a browser package that names no source is refused as a browser_backend error" true
    (match load "\"browser\"" "" with
     | Ok _ -> false
     | Error error -> contains (Lane_addon_manifest.error_to_string error) "browser_backend");
  let ego=match load "\"browser\"\nbrowser_backend = \"ego\"" "" with Ok package -> package
    | Error error -> fail (Lane_addon_manifest.error_to_string error) in
  check bool "a browser package names the one source its worker serves" true
    (ego.worker_service=Lane_addon_types.Browser_service Browser_lane.Backend.Ego);
  check bool "browser selection survives revision serialization" true
    (Yojson.Safe.Util.member "service" (Lane_addon_types.package_to_json ego)=`String "browser");
  check bool "its source survives revision serialization" true
    (Yojson.Safe.Util.member "browser_backend" (Lane_addon_types.package_to_json ego)=`String "ego");
  (* A browser worker answers no host requests, so a browser package that
     declares an exact output or operator asks is refused. *)
  write (Filename.concat packages "answer.json")
    {|{"type":"object","properties":{"ok":{"type":"boolean"}},"required":["ok"],"additionalProperties":false}|};
  List.iter (fun (label, world) -> match load "\"browser\"\nbrowser_backend = \"ego\"" world with
    | Ok _ -> failf "a browser package with %s was accepted" label
    | Error error -> check bool ("a browser package with " ^ label ^ " is refused") true
        (contains (Lane_addon_manifest.error_to_string error) "omit exact_outputs and asks"))
    [ "an exact output", "[world]\nexact_protocol = 1\n[world.exact_outputs.answer]\nschema = \"answer.json\"";
      "operator asks", "[world.asks]\noperator = true" ];
  List.iter (fun (label, service) -> match load service "" with
    | Ok _ -> failf "%s was accepted" label
    | Error error -> check bool (label ^ " is refused as a browser_backend error") true
        (contains (Lane_addon_manifest.error_to_string error) "browser_backend"))
    [ "an unknown source", "\"browser\"\nbrowser_backend = \"chrome\"";
      "a source that is not a string", "\"browser\"\nbrowser_backend = 1";
      "a source on a tools package", "\"tools\"\nbrowser_backend = \"ego\"" ];
  List.iter (fun backend -> check bool (Browser_lane.Backend.to_wire backend ^ " is read as its source") true
    (match load (Printf.sprintf "\"browser\"\nbrowser_backend = %S" (Browser_lane.Backend.to_wire backend)) "" with
     | Ok package -> package.worker_service=Lane_addon_types.Browser_service backend
     | Error _ -> false)) Browser_lane.Backend.all;
  (* With no service the package serves tools, which name no source. *)
  write path {|id = "browser"
revision = "1"
title = "Browser"
runtime = "host_process"
browser_backend = "ego"
command = ["masc-browser-addon-worker"]
contributions = ["observe"]
[resources]
max_reply_bytes = 4096
|};
  check bool "a source with no service is refused as a browser_backend error" true
    (match Lane_addon_manifest.load ~path with
     | Ok _ -> false
     | Error error -> contains (Lane_addon_manifest.error_to_string error) "browser_backend");
  let exported=match load "\"browser\"\nbrowser_backend = \"ego\"" "[world.tools]\nexport = [\"browser_command\"]\ninvocation = \"host_context\"\nhooks = [\"validate_input\", \"validate_output\"]" with
    | Ok package -> package | Error error -> fail (Lane_addon_manifest.error_to_string error) in
  check (list string) "browser exports require host caller context" ["browser_command"] exported.exported_tools;
  check bool "browser selects independent input/output middleware" true
    (exported.tool_invocation=Lane_addon_types.Host_context &&
     exported.tool_hooks=[Lane_addon_types.Validate_input;Validate_output]);
  List.iter (fun (service,extra) -> check bool "unsupported service contract refused" true
    (Result.is_error (load service extra)))
    (* Each browser case names its source, so it is refused for its own
       reason rather than for naming none. *)
    ["\"unknown\"","";"true","";"\"browser\"\nbrowser_backend = \"ego\"","[world.state]\nmode = \"persistent\"";
     "\"browser\"\nbrowser_backend = \"ego\"","[interface]\nmodel_access = \"host_sampling\"";
     "\"browser\"\nbrowser_backend = \"ego\"","[world.tools]\nexport = [\"arbitrary_tool\"]"])

let tool_exports_are_explicit_and_revisioned () = with_directory (fun _root packages directory ->
  let manifest = install_package packages in
  let path = Filename.concat directory "machine.toml" in
  write path (declaration msx_binding);
  let original = unwrap (load_declaration ~path) in
  check (list string) "no implicit exports" [] original.package.exported_tools;
  let install names =
    write manifest (package () ^ "\n[world.tools]\nexport = " ^ names ^ "\n");
    load_declaration ~path in
  let exported = unwrap (install {|["masc_msx_step", "masc_msx_load"]|}) in
  check (list string) "declared tools" ["masc_msx_load"; "masc_msx_step"] exported.package.exported_tools;
  check bool "tool membership changes applied revision" true (original.revision <> exported.revision);
  let reordered = unwrap (install {|["masc_msx_load", "masc_msx_step"]|}) in
  check string "declaration order does not restart worker" exported.revision reordered.revision;
  List.iter (fun names -> check bool ("invalid exports: " ^ names) true (Result.is_error (install names)))
    [ {|["masc_msx_load", "masc_msx_load"]|}; {|["lane_observe"]|}; {|[""]|}; {|[" leading"]|}; {|[7]|} ];
  let removed = unwrap (install "[]") in
  check (list string) "removing exports clears contract" [] removed.package.exported_tools)

let persistent_state_is_explicit_and_revisioned () = with_directory (fun _root packages directory ->
  let manifest = install_package packages in
  let path = Filename.concat directory "machine.toml" in
  write path (declaration msx_binding);
  let original = unwrap (load_declaration ~path) in
  check bool "legacy packages are ephemeral" true
    (original.package.state_storage = Masc.Lane_addon_types.Ephemeral);
  let install state =
    write manifest (package () ^ "\n[world.state]\n" ^ state ^ "\n");
    load_declaration ~path in
  let persistent = unwrap (install {|mode = "persistent"|}) in
  check bool "persistent storage is explicit" true
    (persistent.package.state_storage = Masc.Lane_addon_types.Persistent);
  check bool "storage policy changes installation revision" true
    (persistent.revision <> original.revision);
  List.iter (fun state -> check bool "invalid state contract refused" true
    (Result.is_error (install state)))
    [ {|mode = "writable"|}; {|mode = true|}; {|mode = "persistent"
path = "/host"|} ])

let exact_in_flight_count_is_outside_worker_identity () = with_directory (fun _root packages directory ->
  ignore (install_package packages);
  let path = Filename.concat directory "frames.toml" in
  write path (declaration msx_binding);
  let original = unwrap (load_declaration ~path) in
  check int "a declaration without the key runs one exact request at a time"
    (Config.one_exact_at_a_time :> int) (original.max_exact_in_flight :> int);
  write path (declaration ~extra:"max_exact_in_flight = 3" msx_binding);
  let widened = unwrap (load_declaration ~path) in
  check int "the declared count is read" 3 (widened.max_exact_in_flight :> int);
  check string "the count is not a worker input" original.revision widened.revision;
  List.iter (fun value ->
    write path (declaration ~extra:("max_exact_in_flight = " ^ value) msx_binding);
    check_error ("a count that is not an integer of 1 or more: " ^ value) path)
    ["0"; "-1"; "1.5"; "\"3\""; "true"; "[3]"])

let ui_category_is_strict_display_metadata () = with_directory (fun _root packages directory ->
  let manifest = install_package packages in
  let path = Filename.concat directory "observer.toml" in
  write path (declaration msx_binding);
  let original = unwrap (load_declaration ~path) in
  check bool "absence remains unclassified" true (original.package.ui_category=None);
  let module Category = Lane_addon_category in
  let cases = ["memory_judgment",Category.Memory_and_judgment;
    "browser",Category.Browser;"external_communications",Category.External_communications;
    "voice_media",Category.Voice_and_media;"execution_environment",Category.Execution_environment;
    "analysis",Category.Analysis] in
  List.iter (fun (wire,expected) ->
    write manifest (Printf.sprintf "ui_category = %S\n%s" wire (package ()));
    let found = unwrap (load_declaration ~path) in
    check bool "declared category is typed without using package identity" true
      (found.package.ui_category=Some expected);
    check bool "the package wire retains its original declaration" true
      (Yojson.Safe.Util.member "ui_category" (Lane_addon_types.package_to_json found.package)=`String wire);
    check string "category is excluded from worker input identity" original.revision found.revision;
    check bool "all other worker inputs remain equal" true
      (Lane_addon_types.same_execution_package original.package found.package)) cases;
  let changed = {original.package with ui_category=Some Category.Analysis} in
  List.iter (fun package -> check bool "category never hides a changed worker input" false
    (Lane_addon_types.same_execution_package original.package package))
    [{changed with command=["different-worker"]};
     {changed with model_access=Lane_addon_types.Host_sampling};
     {changed with worker_service=Lane_addon_types.Browser_service Browser_lane.Backend.Ego};
     {changed with tool_hooks=[Lane_addon_types.Validate_input]}];
  List.iter (fun category ->
    write manifest ("ui_category = " ^ category ^ "\n" ^ package ());
    check bool "invalid declared category is not absence or a guessed role" true
      (Result.is_error (load_declaration ~path)))
    ["\"unknown\"";"\"\"";"\"Browser\"";"\" browser\"";"\"browser \"";
     "true";"1";"1.5";"[]";"[\"browser\", \"analysis\"]";"{}";"2026-10-23"];
  write manifest ("ui_category = \"analysis\"\nui_category = \"browser\"\n" ^ package ());
  check bool "duplicate category is rejected before installation" true
    (Result.is_error (load_declaration ~path));
  List.iter (fun value -> check bool "wire categories reject unsupported JSON" true
    (Result.is_error (Category.of_json value)))
    [`Null;`Bool false;`Int 0;`List [];`Assoc [];`String "unknown"];
  check bool "unclassified package wire invents no category" true
    (match Lane_addon_types.package_to_json original.package with
     | `Assoc fields -> not (List.mem_assoc "ui_category" fields)
     | _ -> false))

let ego_installation_space_is_validated_and_revisioned () = with_directory (fun _root packages directory ->
  let manifest=Filename.concat packages "lane.toml" in
  write manifest {|id="ego-fixture"
revision="1"
title="Ego fixture"
runtime="host_process"
service="browser"
browser_backend="ego"
command=["masc-browser-addon-worker"]
contributions=["observe"]
[resources]
max_reply_bytes=4096
|};
  let path=Filename.concat directory "ego.toml" in
  let load space=Config.load_source ~packages:(packages_beside (Filename.dirname path)) ~manifest_scope:Config.Operator_declared ~source_path:path ~source_text:(declaration ("[binding]\nsources=[]\n" ^ space)) in
  let workspace=unwrap (load "") and first=unwrap (load "space=\"first Goal\"\n")
  and second=unwrap (load "space=52\n") in
  check bool "Space is retained in declaration binding" true (Yojson.Safe.Util.member "space" second.binding=`Int 52);
  check bool "two targets and default have distinct semantic revisions" true
    (workspace.revision<>first.revision && first.revision<>second.revision && workspace.revision<>second.revision);
  List.iter (fun space -> check bool "invalid Space fails declaration validation before publication" true
    (Result.is_error (load ("space=" ^ space ^ "\n")))) ["\" \"";"-1";"9007199254740992";"52.0";"true"];
  check bool "source validation wrote no declaration" false (Sys.file_exists path))

let () = run "Lane Add-on declarative composition"
  ["configuration",
    [test_case "Ego installation Space is typed before publication and revisioned" `Quick ego_installation_space_is_validated_and_revisioned;
     test_case "UI category is strict metadata outside worker identity" `Quick ui_category_is_strict_display_metadata;
     test_case "exact in-flight count is read and stays outside worker identity" `Quick exact_in_flight_count_is_outside_worker_identity;
     test_case "browser service is explicit and names only supported capabilities" `Quick browser_service_is_explicit;
      test_case "native execution declares no container isolation" `Quick native_execution_has_no_container_claims;
      test_case "runtime resources name only enforceable limits" `Quick runtime_selects_enforceable_resources;
     test_case "persistent state is explicit and revisioned" `Quick persistent_state_is_explicit_and_revisioned;
     test_case "tool exports are explicit and revisioned" `Quick tool_exports_are_explicit_and_revisioned;
     test_case "alternative probes do not observe tool calls" `Quick alternative_probes_do_not_observe_tool_calls;
     test_case "judge source schema is enforced before worker start" `Quick judge_source_schema_is_enforced;
     test_case "assembled Fusion declarations load with explicit model boundaries" `Quick assembled_fusion_declarations;
     test_case "model access is explicit and changes configuration identity" `Quick model_access_is_explicit_and_revisioned;
     test_case "tool hooks are selectable per installation and revisioned" `Quick tool_hooks_are_selected_and_revisioned;
     test_case "exact outputs are package schemas in the configuration identity" `Quick exact_outputs_are_package_schemas;
     test_case "operator asks are a package declaration" `Quick operator_asks_are_a_package_declaration;
     test_case "host request pages are a package declaration" `Quick host_request_pages_are_a_package_declaration;
     test_case "exact protocol is the one this server speaks" `Quick exact_protocol_is_the_one_this_server_speaks;
     test_case "carried packages are complete manifests" `Quick carried_packages_are_complete_manifests;
     test_case "a declaration names a carried package" `Quick a_declaration_names_a_carried_package;
     test_case "exact outputs are selectable independently from tool hooks" `Quick exact_outputs_are_selected_independently;
     test_case "shipped DOS chain packages declare enforceable binding contracts" `Quick shipped_dos_chain_declares_binding_contracts;
     test_case "the shipped operator quiz declaration loads with its manifest" `Quick shipped_operator_quiz_declaration_loads;
     test_case "the operator quiz worker speaks the host contract" `Quick operator_quiz_worker_speaks_the_host_contract;
     test_case "the shipped operator lesson declaration loads with its manifest" `Quick shipped_operator_lesson_declaration_loads;
     test_case "refresh suppression is an explicit package contract" `Quick refresh_policy_is_explicit;
     test_case "a browser document source names its browser installation" `Quick browser_document_names_its_browser_installation;
     test_case "package interface validates bindings before installation" `Quick package_interface;
     test_case "output ports have exact selections and semantic revisions" `Quick output_ports_are_typed_and_revisioned;
     test_case "relative package and source preserve typed bindings" `Quick relative_package_and_source;
     test_case "comments, rename and key order preserve identity" `Quick comments_rename_and_key_order;
     test_case "meaningful configuration and package changes alter revision" `Quick meaningful_changes;
     test_case "invalid values remain errors" `Quick reject_invalid_values;
     test_case "resources are checked where they are read" `Quick resources_are_checked_where_they_are_read;
     test_case "malformed files retain membership and identity" `Quick invalid_files_remain_visible;
     test_case "duplicate identities do not elect a winner" `Quick duplicates_have_no_winner;
     test_case "missing and unreadable configuration are distinct" `Quick directory_and_read_failures]]
