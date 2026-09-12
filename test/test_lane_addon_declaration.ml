(** The actual declaration owner shared by HTTP and Keeper tools. Only external
    workers are replaced: TOML parsing, files, CAS, reconcile and publication run. *)
open Alcotest
open Masc
module Runtime = Lane_addon_runtime
module Editor = Lane_addon_declaration
module Types = Lane_addon_types
let member = Yojson.Safe.Util.member
let text key json = member key json |> Yojson.Safe.Util.to_string
let list key json = member key json |> Yojson.Safe.Util.to_list
let unwrap = function Ok v -> v | Error error -> fail error.Editor.message
let runtime_result = function Ok v -> v | Error message -> fail message
let write path bytes = Out_channel.with_open_bin path (fun channel -> output_string channel bytes)
let with_env name value f =
  let previous = Sys.getenv_opt name in Unix.putenv name value;
  Fun.protect ~finally:(fun () -> Unix.putenv name (Option.value ~default:"" previous)) f
let output : Types.output = {rows=[];coverage=[]}
let manifest = {|id="editor-test"
revision="1"
title="Editor fixture"
contributions=["observe"]
image="fixture/image"
command=["fixture"]
[resources]
cpus=0.5
memory_bytes=67108864
pids=16
max_reply_bytes=4096
|}
let declaration ?(id="observer") ?(manifest_path="../../package.toml") ?(value="first") () = Printf.sprintf {|id=%S
run_id="editor-world"
manifest_path=%S
[binding]
sources=[]
value=%S
|} id manifest_path value
let request ?revision ~mode ~file_name source_text =
  `Assoc (["mode",`String mode;"file_name",`String file_name;"source_text",`String source_text]
    @ Option.fold ~none:[] ~some:(fun value -> ["expected_source_revision",`String value]) revision)
let read config directory name =
  Runtime.read_declaration ~config (`Assoc ["source_path",`String (Filename.concat directory name)]) |> unwrap
let save config args = Runtime.save_declaration ~config args |> unwrap
let inspect config = Runtime.dispatch ~config ~operation:Runtime.Inspect (`Assoc []) |> runtime_result
let reconcile config directory = Runtime.reconcile_configuration ~config ~directory |> runtime_result
let live config = inspect config |> list "instances" |> List.filter (fun item -> text "kind" (member "phase" item) <> "detached")
let one_live config = match live config with [entry] -> entry | _ -> fail "expected one active installation"
let await clock predicate =
  let rec loop () = if predicate () then () else (Eio.Time.sleep clock 0.001;loop ()) in loop ()
let keeper_call config name args =
  let descriptor = match Keeper_tool_descriptor_resolution.descriptor_for_tool_name name with
    | Some d -> d | None -> fail "Keeper cannot discover declaration tool" in
  check bool "declaration tool is exposed under its Keeper model name" true
    (List.mem name (Keeper_tool_descriptor.keeper_model_names descriptor));
  check bool "Keeper dispatches through the in-process misc owner" true
    (descriptor.runtime_handler=Keeper_tool_descriptor.Tool_masc_misc_dispatch);
  let translated = Keeper_tool_descriptor.translate_input_for_descriptor descriptor args in
  let context : Tool_misc.context = {config;agent_name="editor-keeper";help_schemas=[]} in
  match Tool_misc.dispatch context ~name:descriptor.internal_name ~args:translated with
  | Some value -> value | None -> fail "Keeper descriptor has no executable declaration route"

let with_fixture f =
  let root = Filename.temp_dir "lane-editor-" "" |> Unix.realpath in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree root) (fun () ->
    let config_root = Filename.concat root ".masc/config" in
    let directory = Filename.concat config_root "lane-addons" in
    Fs_compat.mkdir_p directory;
    write (Filename.concat root ".masc/package.toml") manifest;
    with_env "MASC_CONFIG_DIR" config_root (fun () ->
      with_env "MASC_TEST_ALLOW_CONFIG_PATH_OVERRIDE" "true" (fun () ->
        Eio_main.run (fun env ->
          Fs_compat.set_fs (Eio.Stdenv.fs env);
          let clock = Eio.Stdenv.clock env in
          Eio.Time.with_timeout_exn clock 15. (fun () -> Eio.Switch.run (fun sw ->
            Eio_context.with_test_env ~sw ~net:(Eio.Stdenv.net env) ~clock
              ~mono_clock:(Eio.Stdenv.mono_clock env) (fun () ->
                Runtime.For_testing.reset ();
                let started = ref [] in
                let backend : Runtime.For_testing.backend = {
                  start=(fun ~sw:_ ~instance_id ~package:_ ~on_created ->
                    started := instance_id :: !started;
                    let connection : Runtime.For_testing.connection = {
                      observe=(fun ~binding:_ ~sources:_ -> Ok output);
                      action_schema=(fun () -> None);act=(fun ~arguments:_ -> Error "read-only");
                      stop=(fun () -> Ok ());container_id=instance_id} in on_created connection;Ok connection);
                  acquire=(fun ~store:_ ~package:_ ~resolve_lane_output:_ ~binding:_ -> Ok (`List []));
                  recover_stop=(fun ~instance_id:_ ~container_id:_ ~max_reply_bytes:_ -> Ok ())} in
                let config = Workspace.default_config root in
                Runtime.For_testing.with_backend backend (fun () ->
                  f clock config directory root started;
                  Sys.readdir directory |> Array.iter (fun name ->
                    if Filename.check_suffix name ".toml" then Unix.unlink (Filename.concat directory name));
                  ignore (reconcile config directory);
                  await clock (fun () -> live config=[])))))))))

let test_keeper_create_operator_read_and_edit () = with_fixture (fun clock config directory _root started ->
  let bytes = declaration () in
  let created = keeper_call config "masc_lane_declaration_save" (request ~mode:"create" ~file_name:"observer.toml" bytes) in
  check bool "Keeper actually creates the declaration" true (Tool_result.is_success created);
  let receipt = Tool_result.data created in
  check string "create receipt" "created" (member "write" receipt |> text "state");
  check string "apply is not claimed by save" "pending_reconciliation" (text "application" receipt);
  check int "save does not start a worker inline" 0 (List.length !started);
  let observed = read config directory "observer.toml" in
  check string "exact source through operator read" bytes (text "source_text" observed);
  ignore (reconcile config directory);
  await clock (fun () -> List.length !started=1);
  let original_id = one_live config |> text "instance_id" in
  let commented = "# an operator's comment\n" ^ bytes in
  let updated = save config (request ~revision:(text "source_revision" observed) ~mode:"save" ~file_name:"observer.toml" commented) in
  let document = member "document" updated in
  check bool "raw edit changes source revision" true (text "source_revision" observed <> text "source_revision" document);
  check string "comment edit keeps semantic desired revision" (text "desired_revision" observed) (text "desired_revision" document);
  ignore (reconcile config directory);
  check string "comment edit preserves installed worker" original_id (one_live config |> text "instance_id");
  let keeper_read = keeper_call config "masc_lane_declaration_read"
    (`Assoc ["source_path",`String (Filename.concat directory "observer.toml")]) in
  check bool "Keeper can read the operator's edit" true (Tool_result.is_success keeper_read);
  check string "same source bytes" commented (Tool_result.data keeper_read |> text "source_text");
  let same = save config (request ~revision:(text "source_revision" document) ~mode:"save" ~file_name:"observer.toml" commented) in
  check string "identical bytes are not a new edit" "unchanged" (member "write" same |> text "state");
  let changed = save config (request ~revision:(text "source_revision" document) ~mode:"save" ~file_name:"observer.toml" (declaration ~value:"changed" ())) in
  check bool "binding edit changes desired revision" true (text "desired_revision" (member "document" changed) <> text "desired_revision" document);
  check string "saved bytes do not pretend current worker has changed" original_id (one_live config |> text "instance_id");
  ignore (reconcile config directory);
  await clock (fun () -> live config=[]);
  ignore (reconcile config directory);
  await clock (fun () -> List.length !started=2);
  check bool "reconcile owns actual replacement" true (original_id <> (one_live config |> text "instance_id")))

let test_conflicts_and_invalid_candidates_preserve_active () = with_fixture (fun clock config directory _root started ->
  let original = declaration () in
  let created = save config (request ~mode:"create" ~file_name:"observer.toml" original) in
  let revision = member "document" created |> text "source_revision" in
  ignore (reconcile config directory);await clock (fun () -> !started<>[]);
  let instance_id = one_live config |> text "instance_id" in
  let edited = "# external editor\n" ^ original in
  write (Filename.concat directory "observer.toml") edited;
  let conflict = keeper_call config "masc_lane_declaration_save"
    (request ~revision ~mode:"save" ~file_name:"observer.toml" (declaration ~value:"stale" ())) in
  check bool "Keeper gets a real failed outcome" false (Tool_result.is_success conflict);
  let details = Tool_result.data conflict in
  check string "typed conflict survives tool boundary" "revision_conflict" (text "code" details);
  check string "current raw document accompanies conflict" edited (member "current" details |> text "source_text");
  let current = read config directory "observer.toml" in
  List.iter (fun args ->
    match Runtime.save_declaration ~config args with
    | Error error -> check bool "invalid candidate is a typed rejection" true (error.code=Editor.Invalid_declaration)
    | Ok _ -> fail "invalid candidate was written")
    [request ~revision:(text "source_revision" current) ~mode:"save" ~file_name:"observer.toml" "id = [";
     request ~mode:"create" ~file_name:"duplicate.toml" original];
  check bool "duplicate file was never published" false (Sys.file_exists (Filename.concat directory "duplicate.toml"));
  check string "existing bytes remain exact" edited (read config directory "observer.toml" |> text "source_text");
  ignore (reconcile config directory);
  check string "invalid edits never retire active worker" instance_id (one_live config |> text "instance_id"))

let test_invalid_existing_source_can_be_repaired () = with_fixture (fun _clock config directory root _started ->
  let path = Filename.concat directory "broken.toml" in
  write path "id = [";
  let broken = read config directory "broken.toml" in
  check bool "invalid source remains readable" false (member "valid" (member "validation" broken) |> Yojson.Safe.Util.to_bool);
  write path ("id=\"duplicate\"\n" ^ declaration ());
  let duplicate = read config directory "broken.toml" in
  check bool "duplicate declaration keys remain readable" false
    (member "valid" (member "validation" duplicate) |> Yojson.Safe.Util.to_bool);
  write path "id = [";
  let saved = save config (request ~revision:(text "source_revision" broken) ~mode:"save" ~file_name:"broken.toml" (declaration ())) in
  check bool "repair validates using the final relative path" true
    (member "valid" (member "validation" (member "document" saved)) |> Yojson.Safe.Util.to_bool);
  let package_path = Filename.concat root ".masc/package.toml" in
  write package_path ("id=\"duplicate\"\n" ^ manifest);
  let missing_manifest = read config directory "broken.toml" in
  check string "invalid package still permits reading declaration bytes" (declaration ()) (text "source_text" missing_manifest);
  check bool "duplicate manifest is reported, not an uncaught exception" false
    (member "valid" (member "validation" missing_manifest) |> Yojson.Safe.Util.to_bool);
  Unix.unlink package_path;
  let missing = read config directory "broken.toml" in
  check string "missing package still permits reading declaration bytes" (declaration ()) (text "source_text" missing);
  check bool "a missing dependency does not hide the declaration inventory" true
    (Lane_addon_config.load ~directory).complete;
  write (Filename.concat root ".masc/replacement-package.toml") manifest;
  let repaired_source = declaration ~manifest_path:"../../replacement-package.toml" () in
  let repaired = save config (request ~revision:(text "source_revision" missing) ~mode:"save"
    ~file_name:"broken.toml" repaired_source) |> member "document" in
  check bool "saving another manifest repairs the declaration" true
    (member "valid" (member "validation" repaired) |> Yojson.Safe.Util.to_bool);
  check string "replacement declaration bytes are committed" repaired_source
    (read config directory "broken.toml" |> text "source_text");
  check bool "replacement manifest has a new semantic revision" true
    (text "desired_revision" repaired <> text "desired_revision" (member "document" saved));
  check bool "repair did not recreate the missing dependency" false (Sys.file_exists package_path);
  let unreadable = Filename.concat directory "unreadable.toml" in
  Unix.mkdir unreadable 0o700;
  Fun.protect ~finally:(fun () -> Unix.rmdir unreadable) (fun () ->
    check bool "an unreadable declaration makes inventory incomplete" false
      (Lane_addon_config.load ~directory).complete;
    match Runtime.save_declaration ~config (request ~revision:(text "source_revision" repaired)
      ~mode:"save" ~file_name:"broken.toml" ("# cannot inventory peers\n" ^ repaired_source)) with
    | Error error -> check bool "unreadable inventory still blocks publication" true (error.code=Editor.Io_error)
    | Ok _ -> fail "saved without a readable declaration inventory");
  check string "unreadable inventory did not change committed bytes" repaired_source
    (read config directory "broken.toml" |> text "source_text"))

let test_request_paths_and_create_are_exact () = with_fixture (fun _clock config directory root _started ->
  let bytes = declaration () in
  List.iter (fun args -> check bool "invalid mode/revision combination refused" true
    (Result.is_error (Runtime.save_declaration ~config args)))
    [request ~mode:"save" ~file_name:"a.toml" bytes;
     request ~revision:(String.make 64 'a') ~mode:"create" ~file_name:"a.toml" bytes;
     request ~mode:"create" ~file_name:"../outside.toml" bytes;
     request ~mode:"create" ~file_name:"nested/a.toml" bytes];
  ignore (save config (request ~mode:"create" ~file_name:"a.toml" bytes));
  (match Runtime.save_declaration ~config (request ~mode:"create" ~file_name:"a.toml" bytes) with
   | Error error -> check bool "create never overwrites" true (error.code=Editor.Revision_conflict)
   | Ok _ -> fail "create replaced an existing declaration");
  let outside = Filename.concat root "outside.toml" in write outside bytes;
  Unix.symlink outside (Filename.concat directory "link.toml");
  List.iter (fun source_path ->
    check bool "read has no arbitrary filesystem path escape" true
      (Result.is_error (Runtime.read_declaration ~config (`Assoc ["source_path",`String source_path]))))
    [outside;Filename.concat directory "link.toml"])

let test_two_writers_and_post_rename_failure () = with_fixture (fun _clock config directory _root _started ->
  let bytes = declaration () in
  let first = save config (request ~mode:"create" ~file_name:"a.toml" bytes) in
  let revision = member "document" first |> text "source_revision" in
  let args value = request ~revision ~mode:"save" ~file_name:"a.toml" (declaration ~value ()) in
  let a,b = Eio.Fiber.pair (fun () -> Runtime.save_declaration ~config (args "a"))
    (fun () -> Runtime.save_declaration ~config (args "b")) in
  check int "one writer owns the observed source revision" 1 (List.length (List.filter Result.is_ok [a;b]));
  check int "the other writer observes the committed conflict" 1 (List.length (List.filter Result.is_error [a;b]));
  let current = read config directory "a.toml" in
  let next = declaration ~value:"visible-after-fsync-failure" () in
  let request = Editor.write_request (request ~revision:(text "source_revision" current) ~mode:"save" ~file_name:"a.toml" next) |> unwrap in
  let replace_file path source = Fs_compat.Atomic_replace_for_testing.save_file_atomic_strict_staged
    ~sync_parent:(fun _ -> raise (Unix.Unix_error (Unix.EIO,"fsync",directory)))
    path source in
  let receipt = Eio_unix.run_in_systhread (fun () -> Editor.For_testing.write ~replace_file ~directory request) |> unwrap in
  let json = Editor.receipt_to_json receipt in
  check string "post-rename result records visible save" "saved" (member "write" json |> text "state");
  check string "failed parent fsync is not claimed durable" "unconfirmed" (member "write" json |> text "durability");
  check string "published bytes were not silently rolled back" next (read config directory "a.toml" |> text "source_text"))

let test_create_publication_collision_preserves_competing_bytes () = with_fixture (fun _clock config directory _root _started ->
  let path = Filename.concat directory "contested.toml" in
  let competing = declaration ~id:"external-writer" () in
  let staged_path = ref None in
  let replace_file staged bytes =
    staged_path := Some staged;
    match Fs_compat.save_file_atomic_strict_staged staged bytes with
    | Error error -> Error error
    | Ok () -> write path competing; Ok () in
  let request = Editor.write_request (request ~mode:"create" ~file_name:"contested.toml" (declaration ())) |> unwrap in
  (match Eio_unix.run_in_systhread (fun () -> Editor.For_testing.write ~replace_file ~directory request) with
   | Error error -> check bool "publication refuses a concurrently created file" true (error.code=Editor.Revision_conflict)
   | Ok _ -> fail "create overwrote the competing publication");
  check string "competing source bytes survive" competing (read config directory "contested.toml" |> text "source_text");
  match !staged_path with
  | None -> fail "publication staging was not exercised"
  | Some path -> check bool "owned staging is cleaned after refused publication" false (Sys.file_exists path))

let () = run "Lane declaration editing" ["shared TOML owner",[
  test_case "Keeper creates and operator edits the same TOML" `Quick test_keeper_create_operator_read_and_edit;
  test_case "conflict and invalid candidate preserve active installation" `Quick test_conflicts_and_invalid_candidates_preserve_active;
  test_case "invalid source and missing package remain repairable" `Quick test_invalid_existing_source_can_be_repaired;
  test_case "mode, create-only and direct-child path boundaries" `Quick test_request_paths_and_create_are_exact;
  test_case "create publication collision preserves the competing file" `Quick test_create_publication_collision_preserves_competing_bytes;
  test_case "concurrent editors and visible post-rename failure" `Quick test_two_writers_and_post_rename_failure]]
