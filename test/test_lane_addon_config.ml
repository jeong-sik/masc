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
  check bool "source revision tracks exact edited bytes" true (initial.source_revision <> reordered.source_revision);
  let renamed = Filename.concat directory "renamed.toml" in
  Sys.rename path renamed;
  let snapshot = Config.load ~directory in
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
  check bool "an explicit date string remains package data" true (Result.is_ok (Config.load_file ~path));
  (* #41135 introduced the enabled deployment flag: a valid boolean must be
     accepted, not rejected by the unknown-field guard. *)
  write path (declaration ~extra:"enabled = false" msx_binding);
  let disabled = unwrap (Config.load_file ~path) in
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

let output_ports_are_typed_and_revisioned () = with_directory (fun _root packages directory ->
  let manifest = install_package packages in
  let path = Filename.concat directory "frames.toml" in
  write path (declaration msx_binding);
  let install ports = write manifest (package () ^ ports); Config.load_file ~path in
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
  let initial = unwrap (Config.load_file ~path) in
  check int "package declares one display reading" 1 (List.length initial.package.presentation.readings);
  write path (declaration (msx_binding ^ "limit = 0\n"));
  check_error "invalid package binding rejected before worker install" path;
  write path (declaration msx_binding);
  check_error "missing required package binding rejected" path)

let refresh_policy_is_explicit () = with_directory (fun _root packages directory ->
  let manifest = install_package packages in
  let path = Filename.concat directory "refresh.toml" in
  write path (declaration msx_binding);
  let initial = unwrap (Config.load_file ~path) in
  check bool "omitted refresh policy preserves every callback" true
    (initial.package.refresh_policy=Lane_addon_types.Every_hint);
  write manifest (package () ^ "\n[interface]\nrefresh_policy = \"source_changes\"\n");
  let opted_in = unwrap (Config.load_file ~path) in
  check bool "suppression requires a typed package opt-in" true
    (opted_in.package.refresh_policy=Lane_addon_types.Source_changes);
  check bool "refresh policy changes the applied configuration identity" false
    (initial.revision=opted_in.revision);
  write manifest (package () ^ "\n[interface]\nrefresh_policy = \"guess\"\n");
  check_error "unknown refresh policy is rejected" path)


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
    let loaded = unwrap (Config.load_file ~path:(repo_file relative)) in
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
    ignore (unwrap (Config.load_file ~path));
    candidate ~package:"value-difference" ("[binding]\nunit = \"count\"\n" ^ source);
    check_error "value-difference without the compared field is rejected before install" path;
    candidate ~package:"value-difference" ("[binding]\nfield = \"counter\"\nunit = \"count\"\nwindow = 3\n" ^ source);
    check_error "value-difference rejects a binding key the package does not read" path;
    candidate ~package:"output-statistics" ("[binding]\n" ^ source);
    ignore (unwrap (Config.load_file ~path));
    candidate ~package:"output-statistics" "[binding]\nsources = [{source_id = \"game\", kind = \"msx_capture\"}]\n";
    check_error "output-statistics accepts lane_output inputs only" path;
    candidate ~package:"dos-world" "[binding]\nsources = []\n";
    ignore (unwrap (Config.load_file ~path));
    candidate ~package:"dos-world" ("[binding]\n" ^ source);
    check_error "dos-world takes no external source" path)

let tool_hooks_are_selected_and_revisioned () = with_directory (fun _root packages directory ->
  let manifest = install_package packages in
  let path = Filename.concat directory "hooks.toml" in
  write path (declaration msx_binding);
  let initial = unwrap (Config.load_file ~path) in
  check bool "old package has no hooks" true (initial.package.tool_hooks = []);
  check bool "no hook key changes old package identity" true
    (Yojson.Safe.Util.member "tool_hooks" (Lane_addon_types.package_to_json initial.package) = `Null);
  write manifest (package () ^ "\n[world.tools]\nexport = [\"machine_step\"]\nhooks = [\"validate_output\"]\n");
  let default = unwrap (Config.load_file ~path) in
  check bool "package selects output validation" true
    (default.package.tool_hooks = [Lane_addon_types.Validate_output]);
  write path (declaration ~extra:"tool_hooks = []" msx_binding);
  let off = unwrap (Config.load_file ~path) in
  check bool "installation can turn optional hooks off" true (off.package.tool_hooks = []);
  check bool "hook change replaces the worker identity" true (off.revision <> default.revision);
  write path (declaration ~extra:"tool_hooks = [\"validate_input\"]" msx_binding);
  let input = unwrap (Config.load_file ~path) in
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
  let initial = unwrap (Config.load_file ~path) in
  check bool "omitted model access grants no sampling" true
    (initial.package.model_access=Lane_addon_types.Model_disabled);
  write manifest (package () ^ "\n[interface]\nmodel_access = \"host_sampling\"\n");
  let enabled = unwrap (Config.load_file ~path) in
  check bool "model access is a typed explicit package requirement" true
    (enabled.package.model_access=Lane_addon_types.Host_sampling);
  check bool "model access changes the applied configuration identity" false
    (initial.revision=enabled.revision);
  write manifest (package () ^ "\n[interface]\nmodel_access = \"disabled\"\n");
  let disabled = unwrap (Config.load_file ~path) in
  check bool "explicitly disabled and omitted have identical semantics" true
    (initial.revision=disabled.revision);
  List.iter (fun value ->
    write manifest (package () ^ "\n[interface]\nmodel_access = " ^ value ^ "\n");
    check_error "unknown or untyped model access is rejected" path) ["\"auto\"";"true"])

let contains text needle =
  let width = String.length needle in
  let rec at index =
    index + width <= String.length text
    && (String.sub text index width = needle || at (index + 1)) in
  at 0

let exact_outputs_are_package_schemas () = with_directory (fun root packages directory ->
  let manifest = install_package packages in
  let path = Filename.concat directory "quiz.toml" in
  write path (declaration msx_binding);
  let schemas = Filename.concat packages "schemas" in
  Unix.mkdir schemas 0o700;
  let author = {|{"type":"object","properties":{"questions":{"type":"array","items":{"type":"string"}}},"required":["questions"],"additionalProperties":false}|} in
  write (Filename.concat schemas "author.json") author;
  write (Filename.concat schemas "grade.json") {|{"type":"object","properties":{"verdict":{"type":"string","enum":["correct","incorrect"]}},"additionalProperties":false}|};
  let with_outputs tables = write manifest (package () ^ "\n" ^ tables) in
  let initial = unwrap (Config.load_file ~path) in
  check int "a package without the table declares no exact output" 0
    (List.length initial.package.exact_outputs);
  check bool "and its package value carries no exact_outputs key, so its revision is unchanged" true
    (Yojson.Safe.Util.member "exact_outputs" (Lane_addon_types.package_to_json initial.package) = `Null);
  with_outputs {|[world.exact_outputs.grade]
schema = "schemas/grade.json"
[world.exact_outputs.author]
schema = "schemas/author.json"
|};
  let declared = unwrap (Config.load_file ~path) in
  check (list string) "outputs are listed in name order" ["author"; "grade"]
    (List.map (fun (output : Lane_addon_types.exact_output) -> output.name) declared.package.exact_outputs);
  check bool "the schema is the file's JSON" true
    ((List.hd declared.package.exact_outputs).schema = Yojson.Safe.from_string author);
  check bool "declaring exact outputs changes the configuration identity" false
    (initial.revision = declared.revision);
  write (Filename.concat schemas "grade.json") {|{"type":"object","properties":{"verdict":{"type":"string"}},"additionalProperties":false}|};
  let edited = unwrap (Config.load_file ~path) in
  check bool "editing a schema file changes the configuration identity" false
    (declared.revision = edited.revision);
  write manifest (package ());
  check string "removing the table returns to the first identity" initial.revision
    (unwrap (Config.load_file ~path)).revision;
  write (Filename.concat schemas "text.json") {|{"type":"string"}|};
  write (Filename.concat schemas "pattern.json") {|{"type":"object","patternProperties":{"^a":{"type":"string"}},"additionalProperties":false}|};
  write (Filename.concat schemas "broken.json") {|{"type":"object",|};
  write (Filename.concat root "outside.json") author;
  Unix.symlink (Filename.concat root "outside.json") (Filename.concat schemas "escape.json");
  List.iter (fun (label, tables) ->
    with_outputs tables;
    match Config.load_file ~path with
    | Ok _ -> failf "%s was accepted" label
    | Error message ->
        check bool (label ^ " is refused by the exact_outputs reader") true
          (contains message "world.exact_outputs"))
    [ "a directory", "[world.exact_outputs.author]\nschema = \"schemas\"\n";
      "an upper-case name", "[world.exact_outputs.Author]\nschema = \"schemas/author.json\"\n";
      "a name starting with a digit", "[world.exact_outputs.2nd]\nschema = \"schemas/author.json\"\n";
      "a key beside schema", "[world.exact_outputs.author]\nschema = \"schemas/author.json\"\nmodel = \"x\"\n";
      "no schema", "[world.exact_outputs.author]\n";
      "an empty table", "[world.exact_outputs]\n";
      "a parent path", "[world.exact_outputs.author]\nschema = \"../outside.json\"\n";
      "an absolute path", Printf.sprintf "[world.exact_outputs.author]\nschema = %S\n" (Filename.concat root "outside.json");
      "a missing file", "[world.exact_outputs.author]\nschema = \"schemas/absent.json\"\n";
      "a symlink out of the package", "[world.exact_outputs.author]\nschema = \"schemas/escape.json\"\n";
      "invalid JSON", "[world.exact_outputs.author]\nschema = \"schemas/broken.json\"\n";
      "a schema that is not an object", "[world.exact_outputs.author]\nschema = \"schemas/text.json\"\n";
      "an unsupported keyword", "[world.exact_outputs.author]\nschema = \"schemas/pattern.json\"\n" ])

let assembled_fusion_declarations () =
  List.iter (fun name ->
    let loaded = unwrap (Config.load_file ~path:(repo_file
      ("docs/examples/lane-addons/fusion-compute/" ^ name ^ ".toml"))) in
    check string "assembled workers belong to one host run" "assembled-fusion" loaded.run_id;
    let expected = if name="report" then Lane_addon_types.Model_disabled
      else Lane_addon_types.Host_sampling in
    check bool "computation has explicit model access; reporting has none" true
      (loaded.package.model_access=expected);
    check bool "the shipped installation has an enforceable binding schema" true
      (Option.is_some loaded.package.binding_schema)) ["panel-a";"panel-b";"judge";"report"]

let judge_source_schema_is_enforced () =
  let loaded = unwrap (Config.load_file ~path:(repo_file
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
    check bool "Config.load_file rejects unusable judge snapshot declaration" true (Result.is_error (Config.load_file ~path));
    write path (declaration "panel");
    check bool "Config.load_file accepts panel snapshot declaration" true (Result.is_ok (Config.load_file ~path)));
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
  let apple = match load "apple_container" "1" "67108864" "" with
    | Ok package -> package | Error error -> fail (Lane_addon_manifest.error_to_string error) in
  check bool "explicit microVM runtime" true ((unwrap (Lane_addon_types.container apple)).runtime = Lane_addon_types.Apple_container);
  check bool "no imaginary PID cgroup" true ((unwrap (Lane_addon_types.container apple)).resources.pids = None);
  List.iter (fun (runtime,cpus,memory,pids) ->
    check bool "unsupported resource contract refused" true
      (Result.is_error (load runtime cpus memory pids)))
    ["apple_container","0.5","67108864","";
     "apple_container","1","67108865","";
     "apple_container","1","67108864","pids = 16";
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
  let browser=match load "\"browser\"" "" with Ok package -> package
    | Error error -> fail (Lane_addon_manifest.error_to_string error) in
  check bool "browser service is a typed package contract" true
    (browser.worker_service=Lane_addon_types.Browser_service);
  check bool "browser selection survives revision serialization" true
    (Yojson.Safe.Util.member "service" (Lane_addon_types.package_to_json browser)=`String "browser");
  List.iter (fun (service,extra) -> check bool "unsupported service contract refused" true
    (Result.is_error (load service extra)))
    ["\"unknown\"","";"true","";"\"browser\"","[world.state]\nmode = \"persistent\"";
     "\"browser\"","[interface]\nmodel_access = \"host_sampling\"";
     "\"browser\"","[world.tools]\nexport = [\"arbitrary_tool\"]"])

let tool_exports_are_explicit_and_revisioned () = with_directory (fun _root packages directory ->
  let manifest = install_package packages in
  let path = Filename.concat directory "machine.toml" in
  write path (declaration msx_binding);
  let original = unwrap (Config.load_file ~path) in
  check (list string) "no implicit exports" [] original.package.exported_tools;
  let install names =
    write manifest (package () ^ "\n[world.tools]\nexport = " ^ names ^ "\n");
    Config.load_file ~path in
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
  let original = unwrap (Config.load_file ~path) in
  check bool "legacy packages are ephemeral" true
    (original.package.state_storage = Masc.Lane_addon_types.Ephemeral);
  let install state =
    write manifest (package () ^ "\n[world.state]\n" ^ state ^ "\n");
    Config.load_file ~path in
  let persistent = unwrap (install {|mode = "persistent"|}) in
  check bool "persistent storage is explicit" true
    (persistent.package.state_storage = Masc.Lane_addon_types.Persistent);
  check bool "storage policy changes installation revision" true
    (persistent.revision <> original.revision);
  List.iter (fun state -> check bool "invalid state contract refused" true
    (Result.is_error (install state)))
    [ {|mode = "writable"|}; {|mode = true|}; {|mode = "persistent"
path = "/host"|} ])

let () = run "Lane Add-on declarative composition"
  ["configuration",
    [test_case "browser service is explicit and names only supported capabilities" `Quick browser_service_is_explicit;
      test_case "native execution declares no container isolation" `Quick native_execution_has_no_container_claims;
      test_case "runtime resources name only enforceable limits" `Quick runtime_selects_enforceable_resources;
     test_case "persistent state is explicit and revisioned" `Quick persistent_state_is_explicit_and_revisioned;
     test_case "tool exports are explicit and revisioned" `Quick tool_exports_are_explicit_and_revisioned;
     test_case "judge source schema is enforced before worker start" `Quick judge_source_schema_is_enforced;
     test_case "assembled Fusion declarations load with explicit model boundaries" `Quick assembled_fusion_declarations;
     test_case "model access is explicit and changes configuration identity" `Quick model_access_is_explicit_and_revisioned;
     test_case "tool hooks are selectable per installation and revisioned" `Quick tool_hooks_are_selected_and_revisioned;
     test_case "exact outputs are package schemas in the configuration identity" `Quick exact_outputs_are_package_schemas;
     test_case "shipped DOS chain packages declare enforceable binding contracts" `Quick shipped_dos_chain_declares_binding_contracts;
     test_case "refresh suppression is an explicit package contract" `Quick refresh_policy_is_explicit;
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
