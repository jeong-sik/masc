open Alcotest

(* The Gate replay/resolution wording lives in managed prompt templates
   under the config/prompts/keeper.gate_replay prefix; without a loaded
   registry the
   execution path falls back to bare data and the wording assertions below
   see nothing. Same repo-root idiom test_tool_task_coverage uses — that
   executable passes inside the CI sandbox, so the mechanism is CI-proven. *)
let () =
  Masc.Prompt_defaults.init ()
;;

module KET = struct
  include Masc.Keeper_tool_dispatch_runtime
  include Masc.Keeper_tool_dispatch_runtime.Compatibility
end
module KTE = Masc.Keeper_tool_execution
module KES = Masc.Keeper_tool_shared_runtime
module KTD = Masc.Keeper_tool_descriptor
module Workspace = Masc.Workspace
module Publication_availability =
  Masc.Keeper_publication_recovery_availability
module Recovery_test = Fs_compat_test_support.Publication_recovery_for_testing
module Capability_write_test =
  Fs_compat_test_support.Capability_write_for_testing

let tool_ok ?(tool_name = "") message =
  Tool_result.make_ok ~tool_name ~start_time:0.0 ~data:(`String message) ()
;;

let temp_dir prefix =
  let dir = Filename.temp_file prefix "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir

let cleanup_dir path =
  let rec rm target =
    if Sys.file_exists target then
      if Sys.is_directory target then begin
        Sys.readdir target
        |> Array.iter (fun name -> rm (Filename.concat target name));
        Unix.rmdir target
      end else
        Unix.unlink target
  in
  try rm path with _ -> ()

let mkdir_p path =
  let rec loop dir =
    if dir = "" || dir = "." || Sys.file_exists dir then
      ()
    else (
      loop (Filename.dirname dir);
      Unix.mkdir dir 0o755)
  in
  loop path

let with_env key value f =
  let prior = Sys.getenv_opt key in
  Unix.putenv key value;
  Fun.protect
    ~finally:(fun () ->
      match prior with
      | Some old -> Unix.putenv key old
      | None -> Unix.putenv key "")
    f

let write_file path content =
  let oc = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out oc) @@ fun () ->
  output_string oc content

let read_file path =
  let ic = open_in_bin path in
  Fun.protect ~finally:(fun () -> close_in ic) @@ fun () ->
  really_input_string ic (in_channel_length ic)

let fetch_artifact_exn ~base_path artifact_ref =
  let store = Tool_blob_store.create ~base_path in
  match Tool_blob_store.fetch store ~sha256:artifact_ref.Tool_output.sha256 with
  | Ok (Some payload) -> payload
  | Ok None -> fail "durable replay artifact is missing"
  | Error error -> fail (Tool_blob_store.fetch_error_to_string error)
;;

let project_replay_message_exn ~base_path
    (message : Masc.Keeper_gate_replay.model_message) =
  match message.replay_evidence with
  | None -> fail "model message has no replay evidence"
  | Some evidence ->
    (match
       Masc.Keeper_gate_replay.project_model_input
         ~base_path
         evidence
         [ Agent_core.Types.user_msg message.text ]
     with
     | Ok [ _canonical; projected ] ->
       Agent_core.Types.text_of_content projected.content
     | Ok _ -> fail "replay projection did not append exact evidence"
     | Error detail -> fail (Agent_core.Error.to_string detail))
;;

let make_meta ?(name = "keeper-exec-tools") () =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [
          ("name", `String name);
          ("trace_id", `String "keeper-exec-tools-trace");
        ])
  with
  | Ok meta ->
    (* The decoder leaves a placeholder here that its own file calls a bug to
       read as authority, and nothing overwrote it, so every case ran under
       whatever that placeholder was -- Docker. What this suite measures is
       tool dispatch, not a backend. *)
    { meta with sandbox_profile = Masc_test_deps.fixture_sandbox_profile () }
  | Error err -> failwith ("make_meta failed: " ^ err)

(* Durable HITL intake reads the recipient's metadata to decide whether the
   Keeper exists (#31717), so a fixture that only registers in the in-memory
   registry has its operator decision refused as [Hitl_recipient_absent] and
   never writes the resolution journal the replay then looks for. *)
let create_keeper_meta_exn ~sw ~config (meta : Masc.Keeper_meta_contract.keeper_meta) =
  (match
     Masc.Keeper_owner_registry.install_from_store
       ~sw
       ~operation_runner:None
       ~on_turn_slot_released:None
       config
   with
   | Ok _ -> ()
   | Error error ->
     failwith
       ("keeper owner inventory install failed: "
        ^ Masc.Keeper_owner_registry.install_error_to_string error));
  match
    Masc.Keeper_owner_registry.create_meta ~base_path:config.Workspace.base_path meta
  with
  | Ok _ -> ()
  | Error error ->
    failwith
      ("create_keeper_meta failed: "
       ^ Masc.Keeper_owner_registry.command_error_to_string error)
;;

let playground_file ~config ~meta name =
  let root = KES.keeper_playground_root ~config ~meta in
  mkdir_p root;
  Filename.concat root name

let make_ctx () =
  Masc.Keeper_context_runtime.create ~eio:false ~system_prompt:"test"

let with_exec_fixture
      ?(process = false)
      ?(always_allow = false)
      ?(bind_eio_context = false)
      name
      fn
  =
  let dir = temp_dir name in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      Eio.Switch.run @@ fun sw ->
      if process
      then
        Process_eio.init
          ~cwd_default:Eio.Path.(Eio.Stdenv.fs env / dir)
          ~proc_mgr:(Eio.Stdenv.process_mgr env)
          ~clock:(Eio.Stdenv.clock env);
      let config = Masc.Workspace.default_config dir in
      (match
         Masc.Keeper_approval_queue.install_persistence
           ~base_path:config.base_path
       with
       | Ok _ -> ()
       | Error error ->
         fail
           ("Gate persistence fixture failed: "
            ^ Masc.Keeper_approval_queue.install_error_to_string error));
      let meta =
        let meta = make_meta () in
        if always_allow then { meta with always_allow = Some true } else meta
      in
      create_keeper_meta_exn ~sw ~config meta;
      ignore (Masc.Keeper_registry.For_testing.register ~base_path:config.base_path meta.name meta);
      Fun.protect
        ~finally:(fun () ->
          Masc.Keeper_registry.For_testing.unregister ~base_path:config.base_path meta.name)
        (fun () ->
          Masc_test_deps.with_publication_recovery_registry
            ~sw
            ~fs:(Eio.Stdenv.fs env)
            ~registry_root:dir
            (fun publication_recovery_registry ->
               let publication_recovery =
                 { Publication_availability.provider =
                     Publication_availability.constant
                       (Publication_availability.Available
                          publication_recovery_registry)
                 ; keeper_name = meta.name
                 }
               in
               let run () =
                 fn
                   ~config
                   ~meta
                   ~publication_recovery
                   ~ctx_work:(make_ctx ())
               in
               if bind_eio_context
               then
                 Eio_context.with_test_env
                   ~net:(Eio.Stdenv.net env)
                   ~clock:(Eio.Stdenv.clock env)
                   ~mono_clock:(Eio.Stdenv.mono_clock env)
                   ~sw
                   run
               else run ())))

let parse_json raw =
  try Yojson.Safe.from_string raw with
  | Yojson.Json_error err -> fail ("invalid json: " ^ err)

let structured_tool_output_exn ~base_path content =
  match Tool_output.decode_from_agent_core content with
  | Tool_output.Not_marker -> parse_json content
  | Tool_output.Invalid_marker { detail } -> fail detail
  | Tool_output.Decoded reference ->
    if not (String.equal reference.mime Tool_output.artifact_manifest_mime)
    then fail "tool output marker is not a typed result manifest";
    let payload = fetch_artifact_exn ~base_path reference |> parse_json in
    (match Tool_output.artifact_manifest_of_json payload with
     | Tool_output.Decoded_artifact_manifest { structured_content; _ } ->
       structured_content
     | Tool_output.Not_artifact_manifest -> fail "typed result manifest is absent"
     | Tool_output.Invalid_artifact_manifest { detail } -> fail detail)

let outcome_label = function
  | Tool_result.Completed () -> "success"
  | Tool_result.Deferred () -> "deferred"
  | Tool_result.Failed _ -> "failure"

let tool_call_detail_of_execution tool_name
      (result : KET.executed_tool_result)
  : Masc.Keeper_agent_result.tool_call_detail
  =
  let execution_outcome =
    match result.disposition with
    | Tool_result.Completed () -> Tool_result.Ok
    | Tool_result.Deferred () -> Tool_result.Ok
    | Tool_result.Failed _ -> Tool_result.Error
  in
  { tool_name
  ; provider = "test"
  ; execution_outcome
  ; typed_outcome = None
  ; latency_ms = 1.0
  ; task_id = None
  ; route_evidence = None
  ; input_fingerprint = None
  ; output_fingerprint = None
  }
;;

let non_empty_lines text =
  String.split_on_char '\n' text
  |> List.map String.trim
  |> List.filter (fun line -> line <> "")

let json_list_contains name = function
  | `List values ->
      List.exists
        (function
          | `String value -> String.equal value name
          | _ -> false)
        values
  | _ -> false

let json_contains_tool name = function
  | `Assoc fields ->
      List.exists (fun (_, value) -> json_list_contains name value) fields
  | _ -> false

let json_bool_field ~default field json =
  Yojson.Safe.Util.(member field json |> to_bool_option)
  |> Option.value ~default

let json_string_field ~default field json =
  Yojson.Safe.Util.(member field json |> to_string_option)
  |> Option.value ~default

let check_success_result label result =
  if not (String.equal "success" (outcome_label result.KTE.disposition))
  then
    fail
      (Printf.sprintf
         "%s expected success, got %s: %s"
         label
         (outcome_label result.KTE.disposition)
         result.KTE.raw_output);
  let json = Yojson.Safe.from_string result.KTE.raw_output in
  check bool (label ^ " ok") true (json_bool_field ~default:false "ok" json);
  json

let test_public_read_rejects_unsupported_range_fields () =
  with_exec_fixture
    "keeper_tool_dispatch_runtime_read_rejects_range_fields"
    (fun ~config ~meta ~publication_recovery ~ctx_work ->
      let result =
        KET.execute_keeper_tool_call_with_outcome
          ~config
          ~meta
          ~publication_recovery
          ~ctx_work
          ~name:"Read"
          ~input:
            (`Assoc
               [ "file_path", `String "lib/keeper/keeper_transition_audit.ml"
               ; "start_line", `Int 255
               ])
          ()
      in
      check string "runtime outcome" "failure"
        (outcome_label result.disposition);
      let json =
        match result.data with
        | Some data -> data
        | None -> fail "validation rejection omitted typed data"
      in
      let error =
        Yojson.Safe.Util.(member "error" json |> to_string_option)
        |> Option.value ~default:""
      in
      check bool "error mentions unsupported field" true
        (String_util.contains_substring error "unsupported field");
      check bool "error mentions start_line" true
        (String_util.contains_substring error "start_line");
      check string "validation source" "agent_core_tool_middleware"
        Yojson.Safe.Util.(member "validation" json |> to_string);
      check string "failure class" "policy_rejection"
        Yojson.Safe.Util.(member "failure_class" json |> to_string);
      check bool "dispatch does not add a tutor" true
        Yojson.Safe.Util.(member "tool_tutor" json = `Null);
      check bool "did not reach file runtime" false
        (match Yojson.Safe.Util.member "path_resolution" json with
         | `Assoc _ -> true
         | _ -> false))

let test_public_read_accepts_offset_without_enrichment () =
  with_exec_fixture
    "keeper_tool_dispatch_runtime_read_accepts_offset"
    (fun ~config ~meta ~publication_recovery ~ctx_work ->
      let playground = KES.keeper_default_write_root ~config ~meta in
      let file_path = Filename.concat playground "offset-window.txt" in
      mkdir_p playground;
      write_file file_path "one\ntwo\nthree\n";
      let result =
        KET.execute_keeper_tool_call_with_outcome
          ~config
          ~meta
          ~publication_recovery
          ~ctx_work
          ~name:"Read"
          ~input:
            (`Assoc
               [ "file_path", `String "offset-window.txt"
               ; "offset", `Int 2
               ])
          ()
      in
      let json = check_success_result "offset Read" result in
      check string "offset is a 1-based line coordinate" "two\nthree\n"
        (json_string_field ~default:"" "content" json))

let test_surface_read_rejects_duplicate_dispatch_fields () =
  with_exec_fixture
    "keeper_tool_dispatch_runtime_surface_read_rejects_duplicates"
    (fun ~config ~meta ~publication_recovery ~ctx_work ->
      let run input =
        KET.execute_keeper_tool_call_with_outcome
          ~config
          ~meta
          ~publication_recovery
          ~ctx_work
          ~name:"keeper_surface_read"
          ~input
          ()
      in
      let duplicate_mode =
        run
          (`Assoc
             [ "surface", `String "discord"
             ; "mode", `String "channel"
             ; "mode", `String "local" ])
      in
      let duplicate_channel =
        run
          (`Assoc
             [ "surface", `String "discord"
             ; "mode", `String "channel"
             ; "channel_id", `String "123"
             ; "channel_id", `String "456" ])
      in
      check bool "duplicate fields produce validation output" true
        (String_util.contains_substring duplicate_mode.raw_output "error_code");
      check string "duplicate mode is named"
        "keeper_surface_read arguments contains duplicate field \"mode\""
        Yojson.Safe.Util.(member "message" (parse_json duplicate_mode.raw_output) |> to_string);
      check bool "duplicate channel produces validation output" true
        (String_util.contains_substring duplicate_channel.raw_output "error_code");
      check string "duplicate channel is not silently selected"
        "keeper_surface_read arguments contains duplicate field \"channel_id\""
        Yojson.Safe.Util.(member "message" (parse_json duplicate_channel.raw_output) |> to_string))

let test_board_runtime_rejects_unknown_route () =
  let meta = make_meta ~name:"keeper-board-runtime-guard" () in
  let raw =
    Masc.Keeper_tool_board_runtime.handle_board_tool
      ~meta
      ~name:"masc_board_not_registered"
      ~args:(`Assoc [])
  in
  let json = Yojson.Safe.from_string raw in
  check string
    "unknown Board route is explicit"
    "unknown_board_tool"
    Yojson.Safe.Util.(member "error" json |> to_string)
;;

(* #31728 removed the per-keeper tool surface, and with it the descriptor's
   tool group -- every name used to be filed under board/fs/memory/... and
   there is no such field any more. The list therefore says which names the
   model can call, and the group axis is gone rather than collapsed into one
   constant key. Absence is checked against the whole payload, not against a
   group that no longer exists, because a lookup on a missing key answers
   "not there" for every name and proves nothing. *)
let test_keeper_tools_list_json_names_the_model_visible_tools () =
  let meta = make_meta () in
  let json = Yojson.Safe.from_string (KES.keeper_tools_list_json ~meta) in
  let active_names =
    Yojson.Safe.Util.(member "descriptor_surface" json |> to_list)
    |> List.concat_map (fun descriptor ->
      Yojson.Safe.Util.(member "active_names" descriptor |> to_list)
      |> List.map Yojson.Safe.Util.to_string)
  in
  let names name = List.mem name active_names in
  let is_model_visible name =
    List.exists
      (fun (s : Masc_domain.tool_schema) -> String.equal s.name name)
      (Masc.Keeper_tool_policy.keeper_model_tool_schemas ())
  in
  check bool "board tool is named" true (names "masc_board_post");
  check bool "voice tool is named" true (names "keeper_voice_speak");
  check bool "task tool is named" true (names "keeper_task_claim");
  check bool "surface read is named" true (names "keeper_surface_read");
  check bool "tools_list is named" true (names "keeper_tools_list");
  check bool "Grep is named" true (names "Grep");
  check bool "Read is named" true (names "Read");
  check bool "memory tool is named" true (names "keeper_memory_search");
  check bool "MASC task tool tracks the model schemas"
    (is_model_visible "masc_transition") (names "masc_transition");
  check bool "MASC plan tool tracks the model schemas"
    (is_model_visible "masc_plan_get_task") (names "masc_plan_get_task");
  check bool "a board-looking name nobody registered is absent" false
    (json_contains_tool "masc_board_fake" json);
  check bool "the internal Grep route is not a model name" false
    (names "tool_search_files");
  let descriptor_surface =
    Yojson.Safe.Util.(member "descriptor_surface" json |> to_list)
  in
  let string_member field obj =
    Yojson.Safe.Util.(member field obj |> to_string)
  in
  let list_member_contains field expected obj =
    json_list_contains expected Yojson.Safe.Util.(member field obj)
  in
  let find_descriptor_in descriptor_surface internal_name =
    match
      List.find_opt
        (fun descriptor ->
           String.equal internal_name (string_member "internal_name" descriptor))
        descriptor_surface
    with
    | Some descriptor -> descriptor
    | None -> fail ("missing descriptor_surface entry for " ^ internal_name)
  in
  let find_descriptor = find_descriptor_in descriptor_surface in
  let tools_list = find_descriptor "keeper_tools_list" in
  check string
    "tools_list schema authority is the TOML registry"
    "canonical_registry"
    (string_member "input_schema_source" tools_list);
  let descriptor_for_internal internal_name =
    match KTD.descriptors_for_internal internal_name with
    | descriptor :: _ -> descriptor
    | [] -> fail ("missing registered descriptor for " ^ internal_name)
  in
  let execute_descriptor = descriptor_for_internal "tool_execute" in
  let execute_fields = KTD.discovery_fields execute_descriptor in
  check string "discovery_fields internal name" "tool_execute"
    (match List.assoc_opt "internal_name" execute_fields with
     | Some (`String internal_name) -> internal_name
     | _ -> fail "discovery_fields missing internal_name");
  check bool "discovery_fields leaves active_names to shared runtime" true
    (Option.is_none (List.assoc_opt "active_names" execute_fields));
  let execute = find_descriptor "tool_execute" in
  check string "Execute public name" "Execute"
    (string_member "public_name" execute);
  check string "Execute executor" "shell_ir"
    (string_member "executor" execute);
  check bool "Execute internal route is not a model name" false
    (list_member_contains "active_names" "tool_execute" execute);
  check bool "Execute active public name listed" true
    (list_member_contains "active_names" "Execute" execute);
  check string "Execute model projection" "preferred_public_name"
    (string_member "keeper_model_projection" execute);
  let policy = Yojson.Safe.Util.member "policy" execute in
  check bool "Execute policy group omitted" true
    (Yojson.Safe.Util.member "policy_group" policy = `Null);
  let schema_shape = Yojson.Safe.Util.member "schema_shape" execute in
  check bool "Execute schema properties include argv" true
    (list_member_contains "properties" "argv" schema_shape);
  check bool "Execute schema properties omit retired executable" false
    (list_member_contains "properties" "executable" schema_shape);
  check bool "Execute schema properties omit retired pipeline" false
    (list_member_contains "properties" "pipeline" schema_shape);
  check bool "Execute schema properties include script" true
    (list_member_contains "properties" "script" schema_shape);
  check bool "Execute schema has no shape errors" true
    (Yojson.Safe.Util.member "schema_errors" schema_shape = `Null);
  let examples = Yojson.Safe.Util.(member "examples" execute |> to_list) in
  let execute_properties =
    Yojson.Safe.Util.(member "properties" schema_shape |> to_list)
    |> List.map Yojson.Safe.Util.to_string
  in
  List.iter
    (fun example ->
       Yojson.Safe.Util.(member "input" example |> to_assoc)
       |> List.iter (fun (key, _) ->
         check bool ("example input property is declared: " ^ key) true
           (List.mem key execute_properties)))
    examples;
  let example_with_program program =
    List.exists
      (fun example ->
         match Yojson.Safe.Util.(member "input" example |> member "argv" |> to_list) with
         | `String argv0 :: _ -> String.equal program argv0
         | _ -> false)
      examples
  in
  check int "Execute has one neutral typed example" 1 (List.length examples);
  check bool "Execute example uses an opaque program identity" true
    (example_with_program "program");
  List.iter
    (fun product_name ->
       check bool ("Execute example excludes product identity " ^ product_name) false
         (example_with_program product_name))
    [ "gh"; "git"; "rg" ];
  check bool "Execute examples use neutral cwd placeholders" true
    (List.for_all
       (fun example ->
          String.equal
            "<allowed-directory>"
            Yojson.Safe.Util.(member "input" example |> member "cwd" |> to_string))
       examples);
  let grep = find_descriptor "tool_search_files" in
  check bool "non-execute descriptor omits examples field" true
    (Yojson.Safe.Util.member "examples" grep = `Null);
  let grep_policy = Yojson.Safe.Util.member "policy" grep in
  check bool "Grep policy group omitted" true
    (Yojson.Safe.Util.member "policy_group" grep_policy = `Null);
  check bool "Grep internal route is not a model name" false
    (list_member_contains "active_names" "tool_search_files" grep);
  check bool "Grep preferred model name listed" true
    (list_member_contains "active_names" "Grep" grep);
  let malformed_execute =
    { (descriptor_for_internal "tool_execute") with
      KTD.input_schema =
        `Assoc
          [ "properties", `String "not-an-object"
          ; "required", `List [ `String "ok"; `Int 1; `String "  " ]
          ; "oneOf", `List [ `String "not-an-object"; `Assoc [ "required", `String "bad" ] ]
          ]
    }
  in
  let malformed_shape =
    Yojson.Safe.Util.(
      `Assoc (KTD.discovery_fields malformed_execute) |> member "schema_shape")
  in
  check bool "malformed schema surfaces property error" true
    (list_member_contains
       "schema_errors"
       "properties: expected object, got string"
       malformed_shape);
  check bool "malformed schema surfaces required error" true
    (list_member_contains
       "schema_errors"
       "required: expected non-empty string, got int"
       malformed_shape);
  check bool "malformed schema surfaces whitespace required error" true
    (list_member_contains
       "schema_errors"
       "required: expected non-empty string, got string"
       malformed_shape);
  check bool "malformed schema surfaces oneOf case error" true
    (list_member_contains
       "schema_errors"
       "oneOf[0]: expected object, got string"
       malformed_shape);
  check bool "malformed schema surfaces oneOf required-shape error" true
    (list_member_contains
       "schema_errors"
       "oneOf[1].required: expected string array, got string"
       malformed_shape);
  let one_of_execute =
    { (descriptor_for_internal "tool_execute") with
      KTD.input_schema =
        `Assoc
          [ "properties", `Assoc [ "argv", `Assoc []; "script", `Assoc [] ]
          ; "oneOf"
          , `List
              [ `Assoc [ "required", `List [ `String "argv" ] ]
              ; `Assoc [ "required", `List [] ]
              ]
          ]
    }
  in
  let one_of_shape =
    Yojson.Safe.Util.(
      `Assoc (KTD.discovery_fields one_of_execute) |> member "schema_shape")
  in
  let one_of_required =
    Yojson.Safe.Util.(member "one_of_required" one_of_shape |> to_list)
  in
  check int "oneOf shape keeps both branches" 2 (List.length one_of_required);
  (match one_of_required with
   | [ argv_branch; empty_branch ] ->
     check bool "oneOf argv branch retained" true
       (json_list_contains "argv" argv_branch);
     check int "oneOf empty-required branch retained" 0
       Yojson.Safe.Util.(empty_branch |> to_list |> List.length)
   | _ -> fail "expected exactly two oneOf required branches");
  let empty_shape =
    Yojson.Safe.Util.(
      `Assoc
        (KTD.discovery_fields
           { (descriptor_for_internal "tool_execute") with
             KTD.input_schema = `Assoc []
           })
      |> member "schema_shape")
  in
  check int "empty schema has no properties" 0
    Yojson.Safe.Util.(member "properties" empty_shape |> to_list |> List.length);
  check int "empty schema has no required names" 0
    Yojson.Safe.Util.(member "required" empty_shape |> to_list |> List.length);
  check bool "empty schema has no shape errors" true
    (Yojson.Safe.Util.member "schema_errors" empty_shape = `Null);
  let old_search =
    Masc.Keeper_tool_in_process_runtime.handle_tools_list_from_meta
      ~meta
      ~args:(`Assoc [ "query", `String "time" ])
      ()
  in
  (match old_search.KTE.disposition with
   | Tool_result.Failed Tool_result.Policy_rejection -> ()
   | Tool_result.Failed class_ ->
     failf
       "retired list query has wrong failure class: %s"
       (Tool_result.tool_failure_class_to_string class_)
   | Tool_result.Completed () | Tool_result.Deferred () ->
     fail "keeper_tools_list still accepted query");
  check string
    "list query rejection is typed"
    "unexpected_arguments"
    (match old_search.data with
     | Some data ->
       Yojson.Safe.Util.(data |> member "error" |> member "kind" |> to_string)
     | None -> fail "list query omitted typed rejection data");
  let compatibility_search =
    Masc.Keeper_tool_in_process_runtime.handle_capability_search_from_meta
      ~args:(`Assoc [ "query", `String "time" ])
      ()
  in
  check string
    "compatibility search requires frozen authority"
    "frozen_surface_required"
    (match compatibility_search.data with
     | Some data ->
       Yojson.Safe.Util.(data |> member "error" |> member "kind" |> to_string)
     | None -> fail "compatibility search omitted typed rejection data");
  ()

let test_execute_with_outcome_missing_file_is_failure () =
  with_exec_fixture "keeper_tool_dispatch_runtime_missing_file"
    (fun ~config ~meta ~publication_recovery ~ctx_work ->
      let repo_dir =
        Filename.concat
          (Filename.concat (KES.keeper_playground_root ~config ~meta) "repos")
          "masc-mcp"
      in
      mkdir_p (Filename.concat repo_dir ".git");
      let result =
        KET.execute_keeper_tool_call_with_outcome
          ~config ~meta ~publication_recovery ~ctx_work
          ~name:"Read"
          ~input:(`Assoc [ ("file_path", `String "config/runtime.toml") ])
          ()
      in
      check string "missing file outcome" "failure"
        (outcome_label result.disposition);
      let json = Yojson.Safe.from_string result.raw_output in
      check string "input path preserved" "config/runtime.toml"
        Yojson.Safe.Util.(member "input_file_path" json |> to_string);
      check bool "raw error remains explicit" true
        (Yojson.Safe.Util.member "error" json <> `Null);
      check bool "no inferred path advice" true
        Yojson.Safe.Util.(member "path_resolution" json = `Null);
      check bool "no inferred repository list" true
        Yojson.Safe.Util.(member "available_repos" json = `Null))

let check_publication_write_rejected label result =
  check string (label ^ " outcome") "failure" (outcome_label result.KTE.disposition);
  (match result.disposition with
   | Tool_result.Failed Tool_result.Runtime_failure -> ()
   | Tool_result.Failed failure_class ->
     failf
       "%s wrong failure class: %s"
       label
       (Tool_result.tool_failure_class_to_string failure_class)
   | Tool_result.Completed () -> fail (label ^ " unexpectedly succeeded")
   | Tool_result.Deferred () -> fail (label ^ " unexpectedly deferred"));
  check string
    (label ^ " concise message")
    "publication recovery registry is still initializing"
    result.raw_output;
  let json =
    match result.data with
    | Some data -> data
    | None -> fail (label ^ " omitted typed failure data")
  in
  check string
    (label ^ " typed error")
    "publication_recovery_unavailable"
    Yojson.Safe.Util.(member "error" json |> to_string);
  check string
    (label ^ " exact state")
    "initializing"
    Yojson.Safe.Util.(member "state" json |> to_string);
  check string
    (label ^ " stable category")
    "registry_initializing"
    Yojson.Safe.Util.(member "category" json |> to_string);
  check bool
    (label ^ " write not executed")
    false
    Yojson.Safe.Util.(member "write_executed" json |> to_bool);
  check bool
    (label ^ " keeper remains active")
    true
    Yojson.Safe.Util.(member "keeper_active" json |> to_bool)
;;

let check_publication_recovery_failure
      ~label
      ~expected_message
      ~state
      ~category
      ~sentinels
      ~target
      result
  =
  check string (label ^ " outcome") "failure" (outcome_label result.KTE.disposition);
  (match result.disposition with
   | Tool_result.Failed Tool_result.Runtime_failure -> ()
   | Tool_result.Failed failure_class ->
     failf
       "%s returned wrong failure class: %s"
       label
       (Tool_result.tool_failure_class_to_string failure_class)
   | Tool_result.Completed () -> fail (label ^ " unexpectedly wrote a file")
   | Tool_result.Deferred () -> fail (label ^ " unexpectedly deferred"));
  check string (label ^ " stable message") expected_message result.raw_output;
  let data =
    match result.data with
    | Some data -> data
    | None -> fail (label ^ " omitted typed failure data")
  in
  check string
    (label ^ " typed error")
    "publication_recovery_unavailable"
    Yojson.Safe.Util.(member "error" data |> to_string);
  check string
    (label ^ " data failure class")
    "runtime_failure"
    Yojson.Safe.Util.(member "failure_class" data |> to_string);
  check string
    (label ^ " state")
    state
    Yojson.Safe.Util.(member "state" data |> to_string);
  check string
    (label ^ " category")
    category
    Yojson.Safe.Util.(member "category" data |> to_string);
  check bool
    (label ^ " write not executed")
    false
    Yojson.Safe.Util.(member "write_executed" data |> to_bool);
  check bool
    (label ^ " keeper remains active")
    true
    Yojson.Safe.Util.(member "keeper_active" data |> to_bool);
  let public_output = result.raw_output ^ Yojson.Safe.to_string data in
  List.iter
    (fun (sentinel_label, sentinel) ->
       check bool
         (label ^ " " ^ sentinel_label ^ " is absent from tool output")
         false
         (String_util.contains_substring public_output sentinel))
    sentinels;
  check bool (label ^ " created no file") false (Sys.file_exists target)
;;

let test_initializing_recovery_isolates_only_publication_writes () =
  with_exec_fixture
    ~always_allow:true
    "keeper_tool_dispatch_recovery_initializing"
    (fun ~config ~meta ~publication_recovery:_ ~ctx_work ->
       let provider_reads = Atomic.make 0 in
       let publication_recovery =
         { Publication_availability.provider =
             (fun () ->
                Atomic.incr provider_reads;
                Publication_availability.Initializing)
         ; keeper_name = meta.name
         }
       in
       let existing_path = playground_file ~config ~meta "existing.txt" in
       let untouched = "original bytes" in
       write_file existing_path untouched;
       let execute ~name ~input =
         KET.execute_keeper_tool_call_with_outcome
           ~config
           ~meta
           ~publication_recovery
           ~ctx_work
           ~name
           ~input
           ()
       in
       let time_result = execute ~name:"keeper_time_now" ~input:(`Assoc []) in
       check string
         "non-file tool continues"
         "success"
         (outcome_label time_result.disposition);
       let read_result =
         execute
           ~name:"Read"
           ~input:(`Assoc [ "file_path", `String existing_path ])
       in
       check string
         "read continues"
         "success"
         (outcome_label read_result.disposition);
       check int
         "non-file and read-only tools perform no recovery acquisition"
         0
         (Atomic.get provider_reads);
       let append_existing =
         execute
           ~name:"tool_write_file"
           ~input:
             (`Assoc
                [ "path", `String existing_path
                ; "mode", `String "append"
                ; "content", `String " + appended"
                ])
       in
       check string
         "append to an existing file remains recovery-independent"
         "success"
         (outcome_label append_existing.disposition);
       check string
         "append publishes exact bytes while recovery initializes"
         (untouched ^ " + appended")
         (read_file existing_path);
       let append_created_path =
         playground_file ~config ~meta "append-created.txt"
       in
       let append_created =
         execute
           ~name:"tool_write_file"
           ~input:
             (`Assoc
                [ "path", `String append_created_path
                ; "mode", `String "append"
                ; "content", `String "created by append"
                ])
       in
       check string
         "append-create remains recovery-independent"
         "success"
         (outcome_label append_created.disposition);
       check string
         "append-create publishes exact bytes while recovery initializes"
         "created by append"
         (read_file append_created_path);
       check int
         "append and append-create do not read the recovery provider"
         0
         (Atomic.get provider_reads);
       let invalid_write =
         execute
           ~name:"Write"
           ~input:
             (`Assoc
                [ "file_path", `String ""
                ; "content", `String "must not be published"
                ])
       in
       check string
         "invalid Write is rejected"
         "failure"
         (outcome_label invalid_write.disposition);
       check int "invalid Write performs no recovery acquisition" 0
         (Atomic.get provider_reads);
       let write_path = playground_file ~config ~meta "must-not-exist.txt" in
       let write_result =
         execute
           ~name:"Write"
           ~input:
             (`Assoc
                [ "file_path", `String write_path
                ; "content", `String "must not be published"
                ])
       in
       check_publication_write_rejected "Write" write_result;
       check int "Write reads provider exactly once" 1 (Atomic.get provider_reads);
       check bool "Write created no file" false (Sys.file_exists write_path);
       let edit_result =
         execute
           ~name:"Edit"
           ~input:
             (`Assoc
                [ "file_path", `String existing_path
                ; "old_string", `String (untouched ^ " + appended")
                ; "new_string", `String "mutated"
                ])
       in
       check_publication_write_rejected "Edit" edit_result;
       check int "Edit reads provider exactly once" 2 (Atomic.get provider_reads);
       check string "Edit preserved exact bytes" (untouched ^ " + appended")
         (read_file existing_path))
;;

let test_identical_keeper_invocations_join_across_production_boundaries () =
  with_exec_fixture
    ~bind_eio_context:true
    "keeper_tool_observation_exact_invocation"
    (fun ~config ~meta ~publication_recovery ~ctx_work ->
       let net =
         match Eio_context.get_net_opt () with
         | Some net -> net
         | None -> fail "test Eio net missing"
       in
       Masc.Keeper_tool_call_log.reset_for_testing ();
       Masc.Keeper_execution_join.For_testing.clear ();
       Masc.Keeper_tool_call_log.init ~base_path:config.base_path ();
       Masc.Keeper_chat_store.append_user_message
         ~base_dir:config.base_path
         ~keeper_name:meta.name
         ~content:
           (String.make
              (Masc.Tool_bridge.default_externalize_threshold_bytes + 1)
              'x')
         ~surface:(Masc.Surface_ref.Dashboard { session_id = None })
         ();
       let bundle =
         Masc.Keeper_tools_agent_core_bundle.For_testing.make_tool_bundle
           ~config
           ~meta
           ~publication_recovery
           ~ctx_snapshot:ctx_work
           ()
       in
       Fun.protect
         ~finally:(fun () ->
           Masc.Keeper_execution_join.For_testing.clear ();
           Masc.Keeper_tool_call_log.reset_for_testing ();
           bundle.cleanup ())
         (fun () ->
            let trace_id = "keeper-tool-observation-exact-invocation" in
            let turn_ctx_cell = Masc.Keeper_tool_call_log.create_turn_ctx_cell () in
            Masc.Keeper_tool_call_log.set_turn_context
              ~cell:turn_ctx_cell
              ~agent_name:meta.name
              ~trace_id
              ~turn:0
              ~keeper_turn_id:1
              ();
            let callback_saw_committed_row = ref true in
            let ready_callbacks : (string * int * int * string) list ref = ref [] in
            let hooks =
              Masc.Keeper_hooks_agent_core.make_hooks
                ~config
                ~meta_ref:(ref meta)
                ~turn_ctx_cell
                ~trace_id
                ~keeper_turn_id:1
                ~on_after_turn_ordinal:ignore
                ~on_tool_result_ready:
                  (fun ~tool_call_id ~turn ~planned_index ~execution_id ->
                     let execution_id = Ids.Execution_id.to_string execution_id in
                     let committed =
                       Masc.Keeper_tool_call_log.read_recent
                         ~keeper_name:meta.name
                         ~n:8
                         ()
                       |> List.exists (function
                         | `Assoc fields ->
                           (match List.assoc_opt "execution_id" fields with
                            | Some (`String stored) -> String.equal stored execution_id
                            | _ -> false)
                         | _ -> false)
                     in
                     if not committed then callback_saw_committed_row := false;
                     ready_callbacks :=
                       (tool_call_id, turn, planned_index, execution_id)
                       :: !ready_callbacks)
                ()
            in
            let event_bus = Agent_core.Event_bus.create () in
            let subscription =
              Agent_core.Event_bus.subscribe
                ~config:
                  (Agent_core.Event_bus.subscription_config
                     ~capacity:8
                     ~overflow:Agent_core.Event_bus.Drop_oldest
                   |> Result.get_ok)
                event_bus
            in
            let agent =
              Agent_core.Agent.create
                ~net
                ~config:
                  { (Agent_core.Types.default_config ~model:"test-model") with
                    name = meta.name
                  }
                ~tools:bundle.tools
                ~options:{ Agent_core.Agent.default_options with hooks }
                ()
            in
            let execute_identical_occurrence () =
              let options = Agent_core.Agent.options agent in
              match
                Agent_core.Agent_tools.execute_tools
                  ~context:(Agent_core.Agent.context agent)
                  ~tools:
                    (Agent_core.Tool_set.to_list (Agent_core.Agent.tools agent))
                  ~hooks:options.hooks
                  ?tool_approval:options.tool_approval
                  ~event_bus:(Some event_bus)
                  ~tracer:options.tracer
                  ~agent_name:meta.name
                  ~turn_count:0
                  ~usage:(Agent_core.Agent.state agent).usage
                  [ Agent_core.Types.ToolUse
                      { id = ""
                      ; name = "keeper_surface_read"
                      ; input =
                          `Assoc
                            [ "surface", `String "dashboard"
                            ; "limit", `Int 1
                            ]
                      }
                  ]
              with
              | Ok
                  { Agent_core.Agent_tools.completed_results = [ result ]
                  ; completion = Agent_core.Agent_tools.Continue_after_batch
                  } ->
                result
              | Ok _ -> fail "identical Keeper invocation returned an unexpected report"
              | Error _ -> fail "identical Keeper invocation failed"
            in
            (* Both calls deliberately have the same provider id, turn, planned
               index, tool and input. Their heap identity is the only occurrence
               discriminator, and neither completion is bridged until both hooks
               have registered their joins. *)
            let first = execute_identical_occurrence () in
            let second = execute_identical_occurrence () in
            check bool
              "production dispatch creates distinct invocation objects"
              false
              (first.invocation == second.invocation);
            check string
              "provider ids are structurally identical"
              (Agent_core.Tool_contract.Invocation.tool_use_id first.invocation)
              (Agent_core.Tool_contract.Invocation.tool_use_id second.invocation);
            check int
              "turns are structurally identical"
              (Agent_core.Tool_contract.Invocation.turn first.invocation)
              (Agent_core.Tool_contract.Invocation.turn second.invocation);
            check int
              "planned indices are structurally identical"
              (Agent_core.Tool_contract.Invocation.planned_index first.invocation)
              (Agent_core.Tool_contract.Invocation.planned_index second.invocation);
            check bool
              "schedules are structurally identical"
              true
              (Agent_core.Tool_contract.Invocation.schedule first.invocation
               = Agent_core.Tool_contract.Invocation.schedule second.invocation);
            check bool
              "completion contracts are structurally identical"
              true
              (Agent_core.Tool_contract.Invocation.completion first.invocation
               = Agent_core.Tool_contract.Invocation.completion second.invocation);
            let original_result_bytes =
              List.map
                (fun (result : Agent_core.Agent_tools.tool_execution_result) ->
                   match Tool_output.decode_from_agent_core result.content with
                   | Tool_output.Decoded reference ->
                     let original =
                       fetch_artifact_exn
                         ~base_path:config.base_path
                         reference
                     in
                     check bool
                       "externalized result is smaller than its original payload"
                       true
                       (String.length result.content < String.length original);
                     String.length original
                   | Tool_output.Not_marker ->
                     fail "production Keeper result was not externalized"
                   | Tool_output.Invalid_marker { detail } ->
                     failf "production Keeper result has invalid marker: %s" detail)
                [ first; second ]
            in
            let expected_original_bytes =
              match original_result_bytes with
              | [ first_bytes; second_bytes ] ->
                check int
                  "identical reads externalize the same original byte count"
                  first_bytes
                  second_bytes;
                first_bytes
              | _ -> fail "expected original byte counts for two Keeper results"
            in
            let completion_json =
              Agent_core.Event_bus.drain subscription
              |> List.filter_map (fun (event : Agent_core.Event_bus.event) ->
                match event.payload with
                | Agent_core.Event_bus.ToolCompleted _ ->
                  Masc.Keeper_event_bridge.native_event_to_json event
                | _ -> None)
            in
            check int
              "both production completions reach the bridge"
              2
              (List.length completion_json);
            let string_member key = function
              | `Assoc fields ->
                (match List.assoc_opt key fields with
                 | Some (`String value) -> Some value
                 | _ -> None)
              | _ -> None
            in
            let event_execution_ids =
              List.map
                (fun json ->
                   match
                     Option.bind
                       (match json with
                        | `Assoc fields -> List.assoc_opt "payload" fields
                        | _ -> None)
                       (string_member "execution_id")
                   with
                   | Some execution_id -> execution_id
                   | None -> fail "bridged Keeper completion has no execution_id")
                completion_json
            in
            check int
              "each occurrence keeps a distinct execution id"
              2
              (List.length (List.sort_uniq String.compare event_execution_ids));
            let log_rows =
              Masc.Keeper_tool_call_log.read_recent
                ~keeper_name:meta.name
                ~n:2
                ()
            in
            check int "both calls reach the durable tool log" 2 (List.length log_rows);
            let log_execution_ids =
              List.map
                (fun row ->
                   match string_member "execution_id" row with
                   | Some execution_id -> execution_id
                   | None -> fail "durable Keeper tool row has no execution_id")
                log_rows
            in
            let ready_callbacks = List.rev !ready_callbacks in
            check bool
              "result-ready callbacks observe their committed rows"
              true
              !callback_saw_committed_row;
            check int
              "one result-ready callback per execution"
              2
              (List.length ready_callbacks);
            List.iter
              (fun (tool_call_id, turn, planned_index, _) ->
                 check string "callback preserves opaque provider id" "" tool_call_id;
                 check int "callback preserves Agent Core turn" 0 turn;
                 check int "callback preserves planned index" 0 planned_index)
              ready_callbacks;
            let callback_execution_ids =
              List.map (fun (_, _, _, execution_id) -> execution_id) ready_callbacks
            in
            check
              (list string)
              "callback and durable-log joins agree"
              (List.sort String.compare log_execution_ids)
              (List.sort String.compare callback_execution_ids);
            check
              (list string)
              "event and durable-log joins agree"
              (List.sort String.compare log_execution_ids)
              (List.sort String.compare event_execution_ids);
            List.iter
              (fun row ->
                 match row with
                 | `Assoc fields ->
                   (match List.assoc_opt "result_bytes" fields with
                    | Some (`Int bytes) ->
                      check int
                        "handler original-byte observation reaches durable row"
                        expected_original_bytes
                        bytes
                    | _ -> fail "durable Keeper tool row has no result_bytes")
                 | _ -> fail "durable Keeper tool row is not an object")
              log_rows;
            check int
              "post hooks consume both handler observations"
              0
              (Masc.Keeper_tool_call_log.pending_truncation_count_for_testing ());
            check int
              "bridge consumes both exact joins"
              0
              (Masc.Keeper_execution_join.For_testing.size ())))
;;

let test_manual_gate_does_not_defer_internal_memory_write () =
  with_exec_fixture
    "keeper_tool_dispatch_manual_memory_write_no_gate"
    (fun ~config ~meta ~publication_recovery ~ctx_work ->
       (match
          Masc.Keeper_gate_mode.set
            config
            ~actor:"test"
            Masc.Keeper_gate_mode.Manual
        with
        | Ok _ -> ()
        | Error detail -> fail ("failed to select Manual Gate mode: " ^ detail));
       let keepers_dir =
         Config_dir_resolver.keepers_dir_for_base_path
           ~base_path:config.base_path
       in
       let memory_path =
         Masc.Keeper_memory_os_current.path_for_keepers_dir
           ~keepers_dir
           ~keeper_id:meta.name
       in
       let result =
         KET.execute_keeper_tool_call_with_outcome
           ~config
           ~meta
           ~publication_recovery
           ~ctx_work
           ~name:"keeper_memory_write"
           ~input:
             (`Assoc
                [ "title", `String "internal memory"
                ; "content", `String "persists without external Gate approval"
                ])
           ()
       in
       check string
         "Manual Gate memory write outcome"
         "success"
         (outcome_label result.KTE.disposition);
       check bool
         "Manual Gate memory write created its snapshot"
         true
         (Sys.file_exists memory_path);
       (match
          Masc.Keeper_memory_os_current.read_for_keepers_dir
            ~keepers_dir
            ~keeper_id:meta.name
        with
        | Ok (Some { facts = [ fact ]; _ }) ->
          check string
            "internal memory write persisted the exact claim"
            "**internal memory** persists without external Gate approval"
            fact.claim
        | Ok (Some snapshot) ->
          failf
            "internal memory write persisted %d facts instead of one"
            (List.length snapshot.facts)
        | Ok None -> fail "internal memory write persisted no snapshot"
        | Error detail -> fail detail);
       (match
          Masc.Keeper_approval_queue.list_pending_entries_for_workspace
            ~base_path:config.base_path
        with
        | Ok [] -> ()
        | Ok entries ->
          failf
            "internal memory write unexpectedly created %d Gate approvals"
            (List.length entries)
        | Error error ->
          fail (Masc.Keeper_approval_queue.storage_error_to_string error)))
;;

let test_publication_initialization_crash_is_redacted () =
  let exception Sensitive_initialization_crash of string in
  with_exec_fixture
    ~always_allow:true
    "keeper_tool_dispatch_recovery_crash_redaction"
    (fun ~config ~meta ~publication_recovery:_ ~ctx_work ->
       let sensitive = "private-publication-bootstrap-cause" in
       let exception_ = Sensitive_initialization_crash sensitive in
       let backtrace = Printexc.get_callstack 32 in
       let publication_recovery =
         { Publication_availability.provider =
             Publication_availability.constant
               (Publication_availability.Initialization_crashed
                  (exception_, backtrace))
         ; keeper_name = meta.name
         }
       in
       let path = playground_file ~config ~meta "crash-must-not-write.txt" in
       let result =
         KET.execute_keeper_tool_call_with_outcome
           ~config
           ~meta
           ~publication_recovery
           ~ctx_work
           ~name:"Write"
           ~input:
             (`Assoc
                [ "file_path", `String path
                ; "content", `String "must not be published"
                ])
           ()
       in
       (match result.disposition with
        | Tool_result.Failed Tool_result.Runtime_failure -> ()
        | Tool_result.Failed failure_class ->
          failf
            "crashed initialization returned wrong failure class: %s"
            (Tool_result.tool_failure_class_to_string failure_class)
        | Tool_result.Completed () -> fail "crashed initialization unexpectedly wrote a file"
        | Tool_result.Deferred () -> fail "crashed initialization unexpectedly deferred");
       check string
         "crash message is concise and redacted"
         "publication recovery registry initialization crashed"
         result.raw_output;
       let data =
         match result.data with
         | Some data -> data
         | None -> fail "crashed initialization omitted typed failure data"
       in
       check
         (testable Yojson.Safe.pp Yojson.Safe.equal)
         "crash data contains only the public typed projection"
         (`Assoc
            [ "error", `String "publication_recovery_unavailable"
            ; "failure_class", `String "runtime_failure"
            ; "state", `String "initialization_crashed"
            ; "category", `String "registry_initialization_crashed"
            ; ( "detail"
              , `String "publication recovery registry initialization crashed" )
            ; "write_executed", `Bool false
            ; "keeper_active", `Bool true
            ])
         data;
       let rendered_data = Yojson.Safe.to_string data in
       let exception_text = Printexc.to_string exception_ in
       let backtrace_text = Printexc.raw_backtrace_to_string backtrace in
       check bool
         "exception payload is absent from message"
         false
         (String_util.contains_substring result.raw_output exception_text);
       check bool
         "exception payload is absent from data"
         false
         (String_util.contains_substring rendered_data exception_text);
       if backtrace_text <> ""
       then (
         check bool
           "backtrace is absent from message"
           false
           (String_util.contains_substring result.raw_output backtrace_text);
         check bool
           "backtrace is absent from data"
           false
           (String_util.contains_substring rendered_data backtrace_text));
       check bool "crashed initialization created no file" false
         (Sys.file_exists path))
;;

let test_publication_reconciliation_evidence_is_redacted () =
  with_exec_fixture
    ~always_allow:true
    "keeper_tool_dispatch_recovery_evidence_redaction"
    (fun ~config ~meta ~publication_recovery ~ctx_work ->
       let registry =
         match publication_recovery.provider () with
         | Publication_availability.Available registry -> registry
         | Publication_availability.Initializing
         | Publication_availability.Registry_unavailable _
         | Publication_availability.Initialization_crashed _
         | Publication_availability.Non_runtime ->
           fail "fixture did not provide its exact recovery registry"
       in
       let fs =
         match Fs_compat.get_fs_opt () with
         | Some fs -> fs
         | None -> fail "fixture did not install its Eio filesystem"
       in
       let workspace_stat =
         Eio.Path.stat ~follow:true Eio.Path.(fs / config.base_path)
       in
       let operation_id_text = "c3f1589a-e8d4-4a91-aad2-5b6bc54528a7" in
       let operation_id =
         match Uuidm.of_string operation_id_text with
         | Some operation_id -> operation_id
         | None -> fail "test operation ID is not a UUID"
       in
       let allowed_root_sentinel =
         Filename.concat config.base_path "private-allowed-root-path-sentinel"
       in
       (match
          Recovery_test.seed_prepared
            ~registry:(registry)
            ~owner:meta.name
            ~operation_id
            ~allowed_root_path:allowed_root_sentinel
            ~allowed_root_device:workspace_stat.dev
            ~allowed_root_inode:workspace_stat.ino
            ~parent_components:[]
            ~parent_device:workspace_stat.dev
            ~parent_inode:workspace_stat.ino
            ~target_leaf:"redaction-target.txt"
            ~permissions:0o600
        with
        | Ok () -> ()
       | Error error ->
          fail (Recovery_test.fixture_error_to_string error));
       (match
          Recovery_test.write_raw_record
            ~registry:(registry)
            ~owner:meta.name
            ~area:Recovery_test.Forensic
            ~record_name:operation_id_text
            ~raw:"{not-the-derived-forensic-record"
        with
        | Ok () -> ()
        | Error error ->
          fail (Recovery_test.fixture_error_to_string error));
       let target = playground_file ~config ~meta "must-not-write.txt" in
       let result =
         KET.execute_keeper_tool_call_with_outcome
           ~config
           ~meta
           ~publication_recovery
           ~ctx_work
           ~name:"Write"
           ~input:
             (`Assoc
                [ "file_path", `String target
                ; "content", `String "must not be published"
                ])
           ()
       in
       check_publication_recovery_failure
         ~label:"blocked recovery"
         ~expected_message:
           "publication recovery lane is blocked by reconciliation"
         ~state:"lane_unavailable"
         ~category:"lane_reconciliation_blocked"
         ~sentinels:
           [ "allowed-root path", allowed_root_sentinel
           ; "operation ID", operation_id_text
           ]
         ~target
         result)
;;

let test_publication_registry_evidence_is_redacted () =
  with_exec_fixture
    ~always_allow:true
    "keeper_tool_dispatch_registry_evidence_redaction"
    (fun ~config ~meta ~publication_recovery:_ ~ctx_work ->
       let fs =
         match Fs_compat.get_fs_opt () with
         | Some fs -> fs
         | None -> fail "fixture did not install its Eio filesystem"
       in
       let registry_path_sentinel =
         Filename.concat
           config.base_path
           "private-registry-exception-path-sentinel"
       in
       let registry_error =
         Eio.Switch.run @@ fun sw ->
         match
           Fs_compat.Publication_recovery.open_registry
             ~sw
             ~fs
             ~registry_root:Eio.Path.(fs / registry_path_sentinel)
         with
         | Error error -> error
         | Ok _ -> fail "missing registry root unexpectedly opened"
       in
       let publication_recovery =
         { Publication_availability.provider =
             Publication_availability.constant
               (Publication_availability.Registry_unavailable registry_error)
         ; keeper_name = meta.name
         }
       in
       let target = playground_file ~config ~meta "registry-must-not-write.txt" in
       let result =
         KET.execute_keeper_tool_call_with_outcome
           ~config
           ~meta
           ~publication_recovery
           ~ctx_work
           ~name:"Write"
           ~input:
             (`Assoc
                [ "file_path", `String target
                ; "content", `String "must not be published"
                ])
           ()
       in
       check_publication_recovery_failure
         ~label:"unavailable registry"
         ~expected_message:"publication recovery registry is unavailable"
         ~state:"registry_unavailable"
         ~category:"registry_unavailable"
         ~sentinels:[ "registry path evidence", registry_path_sentinel ]
         ~target
         result)
;;

let test_publication_write_rereads_live_provider_after_initialization () =
  with_exec_fixture
    ~always_allow:true
    "keeper_tool_dispatch_recovery_transition"
    (fun ~config ~meta ~publication_recovery:fixture_recovery ~ctx_work ->
       let registry =
         match fixture_recovery.provider () with
         | Publication_availability.Available registry -> registry
         | Publication_availability.Initializing
         | Publication_availability.Registry_unavailable _
         | Publication_availability.Initialization_crashed _
         | Publication_availability.Non_runtime ->
           fail "fixture did not provide its exact recovery registry"
       in
       let state = Atomic.make Publication_availability.Initializing in
       let provider_reads = Atomic.make 0 in
       let publication_recovery =
         { Publication_availability.provider =
             (fun () ->
                Atomic.incr provider_reads;
                Atomic.get state)
         ; keeper_name = meta.name
         }
       in
       let path = playground_file ~config ~meta "after-initialization.txt" in
       let execute () =
         KET.execute_keeper_tool_call_with_outcome
           ~config
           ~meta
           ~publication_recovery
           ~ctx_work
           ~name:"Write"
           ~input:
             (`Assoc
                [ "file_path", `String path
                ; "content", `String "available"
                ])
           ()
       in
       let initializing = execute () in
       check_publication_write_rejected "initializing Write" initializing;
       check bool "initializing Write created no file" false (Sys.file_exists path);
       Atomic.set state (Publication_availability.Available registry);
       let available = execute () in
       check string
         "next Write uses available provider"
         "success"
         (outcome_label available.disposition);
       check string "next Write published exact bytes" "available" (read_file path);
       check int "provider was reread once for each Write" 2
         (Atomic.get provider_reads);
       let edit =
         KET.execute_keeper_tool_call_with_outcome
           ~config
           ~meta
           ~publication_recovery
           ~ctx_work
           ~name:"Edit"
           ~input:
             (`Assoc
                [ "file_path", `String path
                ; "old_string", `String "available"
                ; "new_string", `String "edited"
                ])
           ()
       in
       check string
         "next Edit uses available provider"
         "success"
         (outcome_label edit.disposition);
       check string "next Edit published exact bytes" "edited" (read_file path);
       check int "Edit performs exactly one additional provider read" 3
         (Atomic.get provider_reads))
;;

let test_publication_write_cancellation_releases_exact_lane () =
  let exception Cancel_write in
  let dir = temp_dir "keeper_tool_dispatch_recovery_cancel" in
  let registry_dir = Filename.concat dir "recovery" in
  let workspace_dir = Filename.concat dir "workspace" in
  Unix.mkdir registry_dir 0o755;
  Unix.mkdir workspace_dir 0o755;
  let target_path = Filename.concat workspace_dir "target.txt" in
  write_file target_path "old";
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
       Eio_main.run @@ fun env ->
       Fs_compat.set_fs (Eio.Stdenv.fs env);
       Eio.Switch.run @@ fun sw ->
       let fs = Eio.Stdenv.fs env in
       let registry_root = Eio.Path.(fs / registry_dir) in
       let registry =
         match
           Fs_compat.Publication_recovery.open_registry
             ~sw
             ~fs
             ~registry_root
         with
         | Ok registry -> registry
         | Error error ->
           fail
             (Fs_compat.Publication_recovery.registry_error_to_string error)
       in
       (match Fs_compat.Publication_recovery.discover_owners registry with
        | Ok [] -> ()
        | Ok _ -> fail "fresh recovery registry contained an owner"
        | Error error ->
          fail
            (Fs_compat.Publication_recovery.discovery_error_to_string
               error));
       let keeper_name = "publication-write-cancel" in
       let provider_reads = Atomic.make 0 in
       let publication_recovery =
         { Publication_availability.provider =
             (fun () ->
                Atomic.incr provider_reads;
                Publication_availability.Available registry)
         ; keeper_name
         }
       in
       let parent = Eio.Path.(fs / workspace_dir) in
       let parent_stat = Eio.Path.stat ~follow:true parent in
       let recovery_target =
         match
           Fs_compat.atomic_replace_recovery_target
             ~allowed_root_path:workspace_dir
             ~allowed_root_device:parent_stat.dev
             ~allowed_root_inode:parent_stat.ino
             ~parent_components:[]
             ~target_leaf:"target.txt"
             ~permissions:0o644
         with
         | Ok target -> target
         | Error error ->
           fail
             (Fs_compat.atomic_replace_recovery_target_error_to_string error)
       in
       let cancellation_hook_observed = Atomic.make false in
       (match
          Publication_availability.with_access
            publication_recovery
            (fun publication_recovery_access ->
               Eio.Cancel.sub (fun cancellation_context ->
                 Capability_write_test.replace_capability_file
                   ~before_stage:(function
                     | Fs_compat.Acquire_mutation_lease ->
                       Atomic.set cancellation_hook_observed true;
                       Eio.Cancel.cancel cancellation_context Cancel_write;
                       Eio.Fiber.check ()
                     | _ -> ())
                   ~recovery:publication_recovery_access
                   ~parent
                   ~target:recovery_target
                   "cancelled"))
        with
        | exception Eio.Cancel.Cancelled Cancel_write ->
          ()
        | exception exn ->
          fail ("wrong cancellation evidence: " ^ Printexc.to_string exn)
        | Error unavailable ->
          fail
            (Publication_availability.unavailable_to_string unavailable)
        | Ok
            (Fs_compat.Publication_recovery.Lane_released
              (Error error)) ->
          fail (Fs_compat.capability_write_error_to_string error)
        | Ok
            (Fs_compat.Publication_recovery.Lane_released (Ok ()))
        | Ok (Fs_compat.Publication_recovery.Lane_release_failed _) ->
          fail "cancelled publication write returned normally");
       check bool "cancellation occurred inside the real store borrow" true
         (Atomic.get cancellation_hook_observed);
       check int "cancelled write reads provider exactly once" 1
         (Atomic.get provider_reads);
       check string "cancelled write preserves target" "old" (read_file target_path);
       (match
          Publication_availability.with_access
            publication_recovery
            (fun publication_recovery_access ->
               Fs_compat.replace_capability_file
                 ~recovery:publication_recovery_access
                 ~parent
                 ~target:recovery_target
                 "recovered")
        with
        | Ok
            (Fs_compat.Publication_recovery.Lane_released (Ok ())) ->
          ()
        | Ok
            (Fs_compat.Publication_recovery.Lane_released
              (Error error)) ->
          fail (Fs_compat.capability_write_error_to_string error)
        | Ok (Fs_compat.Publication_recovery.Lane_release_failed _) ->
          fail "successful publication failed to release its lane"
        | Error unavailable ->
          fail
            (Publication_availability.unavailable_to_string unavailable));
       check int "next write reacquires the same owner exactly once" 2
         (Atomic.get provider_reads);
       check string "next write succeeds after cancellation cleanup" "recovered"
         (read_file target_path))
;;

let test_real_publication_release_failure_preserves_effect_truth () =
  let exception Injected_release_failure of string in
  let exception Injected_write_failure of string in
  with_exec_fixture
    ~always_allow:true
    "keeper_tool_dispatch_release_failure_effect_truth"
    (fun ~config ~meta ~publication_recovery:fixture_recovery ~ctx_work ->
       let registry =
         match fixture_recovery.provider () with
         | Publication_availability.Available registry -> registry
         | Publication_availability.Initializing
         | Publication_availability.Registry_unavailable _
         | Publication_availability.Initialization_crashed _
         | Publication_availability.Non_runtime ->
           fail "fixture did not provide its exact recovery registry"
       in
       let provider_reads = Atomic.make 0 in
       let publication_recovery =
         { Publication_availability.provider =
             (fun () ->
                Atomic.incr provider_reads;
                Publication_availability.Available registry)
         ; keeper_name = meta.name
         }
       in
       let target = playground_file ~config ~meta "release-effect.txt" in
       let execute_at target content =
         KET.execute_keeper_tool_call_with_outcome
           ~config
           ~meta
           ~publication_recovery
           ~ctx_work
           ~name:"Write"
           ~input:
             (`Assoc
                [ "file_path", `String target
                ; "content", `String content
                ])
           ()
       in
       let execute content = execute_at target content in
       let warmup = execute "warmup" in
       check string "warmup Write succeeds" "success"
         (outcome_label warmup.disposition);
       let release_fault =
         match
           Recovery_test.lane_scope_release_fault
             ~owner:meta.name
             ~exception_:
               (Injected_release_failure
                  "private-release-failure-evidence")
         with
         | Ok fault -> fault
         | Error error ->
           fail (Recovery_test.validation_error_to_string error)
       in
       let committed =
         Recovery_test.with_lane_scope_release_fault release_fault (fun () ->
           execute "committed")
       in
       (match committed.disposition with
        | Tool_result.Failed Tool_result.Runtime_failure -> ()
        | Tool_result.Failed failure_class ->
          failf
            "cleanup failure received wrong class: %s"
            (Tool_result.tool_failure_class_to_string failure_class)
        | Tool_result.Completed () -> fail "cleanup failure was reported as success"
        | Tool_result.Deferred () -> fail "cleanup failure was reported as deferred");
       check string
         "committed effect and cleanup failure are both explicit"
         "filesystem publication committed, but publication recovery lane cleanup failed"
         committed.raw_output;
       let committed_data =
         match committed.data with
         | Some data -> data
         | None -> fail "cleanup failure omitted typed data"
       in
       check
         (testable Yojson.Safe.pp Yojson.Safe.equal)
         "committed cleanup failure has the exact typed public projection"
         (`Assoc
            [ "error", `String "publication_recovery_cleanup_failed"
            ; "failure_class", `String "runtime_failure"
            ; "state", `String "lane_release_failed"
            ; ( "detail"
              , `String
                  "publication recovery lane cleanup failed after the publication callback returned" )
            ; "write_executed", `Bool true
            ; "keeper_active", `Bool true
            ; ( "publication_result"
              , `Assoc [ "outcome", `String "success" ] )
            ])
         committed_data;
       check string "committed bytes reached the real target" "committed"
         (read_file target);
       let recovered = execute "recovered" in
       check string "same Keeper lane recovers on the next Write" "success"
         (outcome_label recovered.disposition);
       check string "recovered Write publishes exact bytes" "recovered"
         (read_file target);
       let write_fault =
         Recovery_test.replace_dispatch_fault
           ~stage:Recovery_test.Before_parent_sync
           ~exception_:
             (Injected_write_failure "private-write-failure-evidence")
       in
       let failed_after_replace =
         Recovery_test.with_lane_scope_release_fault release_fault (fun () ->
           Recovery_test.with_replace_dispatch_fault write_fault (fun () ->
             execute "replaced-before-failure"))
       in
       (match failed_after_replace.disposition with
        | Tool_result.Failed Tool_result.Runtime_failure -> ()
        | Tool_result.Failed failure_class ->
          failf
            "post-replace cleanup failure received wrong class: %s"
            (Tool_result.tool_failure_class_to_string failure_class)
        | Tool_result.Completed () -> fail "post-replace cleanup failure was reported as success"
        | Tool_result.Deferred () -> fail "post-replace cleanup failure was reported as deferred");
       check string
         "post-replace callback and cleanup failures remain explicit"
         "filesystem publication produced an observable filesystem effect before the publication callback and recovery lane cleanup both failed"
         failed_after_replace.raw_output;
       let failed_after_replace_data =
         match failed_after_replace.data with
         | Some data -> data
         | None -> fail "post-replace cleanup failure omitted typed data"
       in
       check
         (testable Yojson.Safe.pp Yojson.Safe.equal)
         "post-replace cleanup failure preserves exact typed effect truth"
         (`Assoc
            [ "error", `String "publication_recovery_cleanup_failed"
            ; "failure_class", `String "runtime_failure"
            ; "state", `String "lane_release_failed"
            ; ( "detail"
              , `String
                  "publication recovery lane cleanup failed after the publication callback returned" )
            ; "write_executed", `Bool true
            ; "keeper_active", `Bool true
            ; ( "publication_result"
              , `Assoc
                  [ "outcome", `String "failure"
                  ; "failure_class", `String "runtime_failure"
                  ; "filesystem_target_effect", `String "target_replaced"
                  ; "filesystem_created_parent_effects", `List []
                  ] )
            ])
         failed_after_replace_data;
       check string
         "post-replace failure retains the bytes observed on disk"
         "replaced-before-failure"
         (read_file target);
       let recovered_after_callback_failure =
         execute "recovered-after-callback-failure"
       in
       check string
         "same Keeper lane recovers after callback and cleanup failure"
         "success"
         (outcome_label recovered_after_callback_failure.disposition);
       let unknown_fault =
         Recovery_test.remove_staging_payload_before_publish ()
       in
       let unknown_target_effect =
         Recovery_test.with_lane_scope_release_fault release_fault (fun () ->
           Recovery_test.with_replace_dispatch_fault unknown_fault (fun () ->
             execute "must-not-replace-existing-target"))
       in
       check string
         "unknown target effect is not guessed as executed or unchanged"
         "filesystem publication callback and publication recovery lane cleanup both failed"
         unknown_target_effect.raw_output;
       let unknown_target_effect_data =
         match unknown_target_effect.data with
         | Some data -> data
         | None -> fail "unknown-target cleanup failure omitted typed data"
       in
       check
         (testable Yojson.Safe.pp Yojson.Safe.equal)
         "unknown target effect remains indeterminate in the public projection"
         (`Assoc
            [ "error", `String "publication_recovery_cleanup_failed"
            ; "failure_class", `String "runtime_failure"
            ; "state", `String "lane_release_failed"
            ; ( "detail"
              , `String
                  "publication recovery lane cleanup failed after the publication callback returned" )
            ; "write_executed", `Null
            ; "keeper_active", `Bool true
            ; ( "publication_result"
              , `Assoc
                  [ "outcome", `String "failure"
                  ; "failure_class", `String "runtime_failure"
                  ; "filesystem_target_effect", `String "target_state_unknown"
                  ; "filesystem_created_parent_effects", `List []
                  ] )
            ])
         unknown_target_effect_data;
       check string
         "failed real rename preserves the prior target bytes"
         "recovered-after-callback-failure"
         (read_file target);
       let recovered_after_unknown = execute "recovered-after-unknown" in
       check string
         "same Keeper lane recovers after indeterminate target observation"
         "success"
         (outcome_label recovered_after_unknown.disposition);
       let created_parent =
         playground_file ~config ~meta "created-parent-effect"
       in
       let nested_target = Filename.concat created_parent "child.txt" in
       let unchanged_fault =
         Recovery_test.replace_dispatch_fault
           ~stage:Recovery_test.Before_publish_replace
           ~exception_:
             (Injected_write_failure "private-before-publish-evidence")
       in
       let parent_effect =
         Recovery_test.with_lane_scope_release_fault release_fault (fun () ->
           Recovery_test.with_replace_dispatch_fault unchanged_fault (fun () ->
             execute_at nested_target "must-not-reach-target"))
       in
       check string
         "created parent remains an observed effect when target is unchanged"
         "filesystem publication produced an observable filesystem effect before the publication callback and recovery lane cleanup both failed"
         parent_effect.raw_output;
       let parent_effect_data =
         match parent_effect.data with
         | Some data -> data
         | None -> fail "created-parent cleanup failure omitted typed data"
       in
       check
         (testable Yojson.Safe.pp Yojson.Safe.equal)
         "created-parent effect joins with the unchanged target effect"
         (`Assoc
            [ "error", `String "publication_recovery_cleanup_failed"
            ; "failure_class", `String "runtime_failure"
            ; "state", `String "lane_release_failed"
            ; ( "detail"
              , `String
                  "publication recovery lane cleanup failed after the publication callback returned" )
            ; "write_executed", `Bool true
            ; "keeper_active", `Bool true
            ; ( "publication_result"
              , `Assoc
                  [ "outcome", `String "failure"
                  ; "failure_class", `String "runtime_failure"
                  ; "filesystem_target_effect", `String "target_unchanged"
                  ; ( "filesystem_created_parent_effects"
                    , `List
                        [ `Assoc
                            [ ( "target_effect"
                              , `String "directory_created_requested_mode" )
                            ; "child_sync", `String "succeeded"
                            ; "parent_sync", `String "succeeded"
                            ]
                        ] )
                  ] )
            ])
         parent_effect_data;
       check bool "created parent remains on disk" true
         (Sys.file_exists created_parent && Sys.is_directory created_parent);
       check bool "failed pre-publish target remains absent" false
         (Sys.file_exists nested_target);
       check int "each real Write reads the provider exactly once" 8
         (Atomic.get provider_reads))
;;

let test_real_directory_release_failure_preserves_effect_truth () =
  let exception Injected_release_failure of string in
  let exception Injected_directory_failure of string in
  with_exec_fixture
    ~always_allow:true
    "keeper_tool_dispatch_directory_release_effect_truth"
    (fun ~config ~meta ~publication_recovery:fixture_recovery ~ctx_work ->
       let registry =
         match fixture_recovery.provider () with
         | Publication_availability.Available registry -> registry
         | Publication_availability.Initializing
         | Publication_availability.Registry_unavailable _
         | Publication_availability.Initialization_crashed _
         | Publication_availability.Non_runtime ->
           fail "fixture did not provide its exact recovery registry"
       in
       let provider_reads = Atomic.make 0 in
       let publication_recovery =
         { Publication_availability.provider =
             (fun () ->
                Atomic.incr provider_reads;
                Publication_availability.Available registry)
         ; keeper_name = meta.name
         }
       in
       let execute target content =
         KET.execute_keeper_tool_call_with_outcome
           ~config
           ~meta
           ~publication_recovery
           ~ctx_work
           ~name:"Write"
           ~input:
             (`Assoc
                [ "file_path", `String target
                ; "content", `String content
                ])
           ()
       in
       let warmup_target = playground_file ~config ~meta "lane-warmup.txt" in
       let warmup = execute warmup_target "warmup" in
       check string "directory matrix warmup succeeds" "success"
         (outcome_label warmup.disposition);
       let release_fault =
         match
           Recovery_test.lane_scope_release_fault
             ~owner:meta.name
             ~exception_:
               (Injected_release_failure
                  "private-directory-release-failure-evidence")
         with
         | Ok fault -> fault
         | Error error ->
           fail (Recovery_test.validation_error_to_string error)
       in
       let run_case
             ~label
             ~stage
             ~expected_message
             ~expected_target_effect
             ~expected_write_executed
             ~expected_directory_exists
         =
         let parent = playground_file ~config ~meta label in
         let target = Filename.concat parent "child.txt" in
         let fault =
           Masc.Keeper_tool_filesystem_runtime.For_testing
           .created_directory_fault
             ~stage
             ~exception_:(Injected_directory_failure label)
         in
         let result =
           Recovery_test.with_lane_scope_release_fault release_fault (fun () ->
             Masc.Keeper_tool_filesystem_runtime.For_testing
             .with_created_directory_fault
               fault
               (fun () -> execute target "must-not-reach-target"))
         in
         (match result.disposition with
          | Tool_result.Failed Tool_result.Runtime_failure -> ()
          | Tool_result.Failed failure_class ->
            failf
              "%s returned wrong failure class: %s"
              label
              (Tool_result.tool_failure_class_to_string failure_class)
          | Tool_result.Completed () -> failf "%s unexpectedly succeeded" label
          | Tool_result.Deferred () -> failf "%s unexpectedly deferred" label);
         check string (label ^ " message") expected_message result.raw_output;
         let data =
           match result.data with
           | Some data -> data
           | None -> failf "%s omitted typed data" label
         in
         check
           (testable Yojson.Safe.pp Yojson.Safe.equal)
           (label ^ " exact typed projection")
           (`Assoc
              [ "error", `String "publication_recovery_cleanup_failed"
              ; "failure_class", `String "runtime_failure"
              ; "state", `String "lane_release_failed"
              ; ( "detail"
                , `String
                    "publication recovery lane cleanup failed after the publication callback returned" )
              ; "write_executed", expected_write_executed
              ; "keeper_active", `Bool true
              ; ( "publication_result"
                , `Assoc
                    [ "outcome", `String "failure"
                    ; "failure_class", `String "runtime_failure"
                    ; ( "filesystem_directory_target_effect"
                      , `String expected_target_effect )
                    ; "filesystem_created_parent_effects", `List []
                    ] )
              ])
           data;
         check bool (label ^ " directory state") expected_directory_exists
           (Sys.file_exists parent && Sys.is_directory parent);
         check bool (label ^ " target remains absent") false
           (Sys.file_exists target)
       in
       let recover_lane content =
         let result = execute warmup_target content in
         check string "same Keeper lane recovers between directory cases"
           "success"
           (outcome_label result.disposition)
       in
       run_case
         ~label:"directory-unchanged"
         ~stage:
           Masc.Keeper_tool_filesystem_runtime.For_testing
           .Before_create_directory
         ~expected_message:
           "filesystem publication left the target unchanged, but publication recovery lane cleanup failed"
         ~expected_target_effect:"directory_unchanged"
         ~expected_write_executed:(`Bool false)
         ~expected_directory_exists:false;
       recover_lane "recovered-after-directory-unchanged";
       run_case
         ~label:"directory-state-unknown"
         ~stage:
           Masc.Keeper_tool_filesystem_runtime.For_testing
           .Before_inspect_created_directory
         ~expected_message:
           "filesystem publication callback and publication recovery lane cleanup both failed"
         ~expected_target_effect:"directory_state_unknown"
         ~expected_write_executed:`Null
         ~expected_directory_exists:true;
       recover_lane "recovered-after-directory-unknown";
       run_case
         ~label:"directory-created-validated"
         ~stage:
           Masc.Keeper_tool_filesystem_runtime.For_testing
           .Before_apply_directory_permissions
         ~expected_message:
           "filesystem publication produced an observable filesystem effect before the publication callback and recovery lane cleanup both failed"
         ~expected_target_effect:"directory_created_validated"
         ~expected_write_executed:(`Bool true)
         ~expected_directory_exists:true;
       check int "each directory matrix Write reads the provider exactly once" 6
         (Atomic.get provider_reads))
;;

let test_model_visible_local_tools_dispatch_to_runtime_handlers () =
  with_exec_fixture
    ~process:true
    ~always_allow:true
    "keeper_tool_dispatch_runtime_model_tools"
    (fun ~config ~meta ~publication_recovery ~ctx_work ->
      let playground = KES.keeper_default_write_root ~config ~meta in
      let visible_file_path = "model-visible.txt" in
      let file_path = Filename.concat playground visible_file_path in
      let run name input =
        KET.execute_keeper_tool_call_with_outcome
          ~config
          ~meta
          ~publication_recovery
          ~ctx_work
          ~name
          ~input
          ()
      in
      let write_result =
        run
          "Write"
          (`Assoc
             [ "file_path", `String visible_file_path
             ; "content", `String "alpha\nbeta\n"
             ])
      in
      ignore (check_success_result "Write" write_result);
      check string "Write changed disk" "alpha\nbeta\n" (read_file file_path);
      let read_result =
        run
          "Read"
          (`Assoc
             [ "file_path", `String visible_file_path; "limit", `Int 4096 ])
      in
      let read_json = check_success_result "Read" read_result in
      check string "Read returns file content" "alpha\nbeta\n"
        (json_string_field ~default:"" "content" read_json);
      let edit_result =
        run
          "Edit"
          (`Assoc
             [ "file_path", `String visible_file_path
             ; "old_string", `String "alpha"
             ; "new_string", `String "gamma"
             ])
      in
      ignore (check_success_result "Edit" edit_result);
      check string "Edit changed disk" "gamma\nbeta\n" (read_file file_path);
      let grep_result =
        run
          "Grep"
          (`Assoc
             [ "pattern", `String "gamma"; "path", `String visible_file_path ])
      in
      let grep_json = check_success_result "Grep" grep_result in
      check string "Grep translates to rg op" "rg"
        (json_string_field ~default:"" "op" grep_json);
      check bool "Grep returns real match" true
        (String_util.contains_substring grep_result.raw_output visible_file_path);
      check bool "Grep match includes content" true
        (String_util.contains_substring grep_result.raw_output "gamma");
      let execute_result =
        run
          "Execute"
          (`Assoc
             [ "argv", `List [ `String "pwd" ]
             ; "cwd", `String playground
             ; "timeout_sec", `Float 5.0
             ])
      in
      let execute_json = check_success_result "Execute" execute_result in
      check bool "Execute used typed Shell IR" true
        (json_bool_field ~default:false "typed" execute_json);
      let observed_cwd =
        json_string_field ~default:"" "output" execute_json |> String.trim
      in
      check string "Execute ran in requested cwd"
        (Unix.realpath playground)
        (Unix.realpath observed_cwd))

let test_keeper_task_claim_accepts_specific_task_id () =
  with_exec_fixture "keeper_tool_dispatch_specific_task_claim"
    (fun ~config ~meta ~publication_recovery ~ctx_work ->
      ignore (Workspace.init config ~agent_name:(Some meta.name));
      ignore
        (Workspace.add_task config ~title:"higher priority task" ~priority:1
           ~description:"should not be claimed by explicit task_id");
      ignore
        (Workspace.add_task config ~title:"requested task" ~priority:3
           ~description:"must be claimed by explicit task_id");
      let result =
        KET.execute_keeper_tool_call_with_outcome
          ~config
          ~meta
          ~publication_recovery
          ~ctx_work
          ~name:"keeper_task_claim"
          ~input:(`Assoc [ "task_id", `String "task-002" ])
          ()
      in
      check string "specific claim outcome" "success" (outcome_label result.disposition);
      let json = Yojson.Safe.from_string result.raw_output in
      let claimed_task = Yojson.Safe.Util.member "claimed_task" json in
      check string "claimed requested task" "task-002"
        Yojson.Safe.Util.(member "task_id" claimed_task |> to_string);
      let tasks = Workspace.get_tasks_raw config in
      let task_status task_id =
        match
          List.find_opt
            (fun (task : Masc_domain.task) -> String.equal task.id task_id)
            tasks
        with
        | None -> fail (Printf.sprintf "missing %s" task_id)
        | Some task -> task.Masc_domain.task_status
      in
      (match task_status "task-001" with
       | Masc_domain.Todo -> ()
       | _ -> fail "higher priority task should remain todo");
      match task_status "task-002" with
      | Masc_domain.Claimed { assignee; _ }
      | Masc_domain.InProgress { assignee; _ } ->
        check string "assignee" meta.name assignee
      | _ -> fail "requested task should be claimed or auto-started")

let test_unknown_tool_returns_exact_error () =
  with_exec_fixture "keeper_tool_dispatch_runtime_unknown_tool"
    (fun ~config ~meta ~publication_recovery ~ctx_work ->
      let result =
        KET.execute_keeper_tool_call_with_outcome
          ~config
          ~meta
          ~publication_recovery
          ~ctx_work
          ~name:"Glob"
          ~input:(`Assoc [ "pattern", `String "*.ml" ])
          ()
      in
      check string "runtime outcome" "failure" (outcome_label result.disposition);
      let json = Yojson.Safe.from_string result.raw_output in
      check string "exact unknown tool error" "unknown_tool"
        Yojson.Safe.Util.(member "error" json |> to_string);
      check string "requested tool preserved" "Glob"
        Yojson.Safe.Util.(member "tool" json |> to_string);
      check bool "no guessed suggestions" true
        Yojson.Safe.Util.(member "did_you_mean" json = `Null);
      check bool "no tutor" true
        Yojson.Safe.Util.(member "tool_tutor" json = `Null))

let test_model_visible_web_search_dispatches_to_misc_runtime () =
  with_exec_fixture ~always_allow:true "keeper_tool_dispatch_web_search"
    (fun ~config ~meta ~publication_recovery ~ctx_work ->
      Masc.Tool_misc.with_web_search_simulation_for_test
        ~outcomes:
          [
            ("brave", `Error "offline");
            ( "searxng",
              `Hits
                [
                  ( "OCaml Eio runtime",
                    "https://example.com/eio",
                    "Fiber <b>runtime</b> evidence" );
                ] );
          ]
        (fun () ->
          let result =
            KET.execute_keeper_tool_call_with_outcome
              ~config
              ~meta
              ~publication_recovery
              ~ctx_work
              ~name:"WebSearch"
              ~input:
                (`Assoc
                  [
                    ("query", `String "ocaml eio runtime test");
                    ("limit", `Int 3);
                  ])
              ()
          in
          check string "web search outcome" "success"
            (outcome_label result.disposition);
          let json = parse_json result.raw_output in
          let result_json = Yojson.Safe.Util.member "result" json in
          check string "status" "ok"
            Yojson.Safe.Util.(member "status" json |> to_string);
          check string "query preserved" "ocaml eio runtime test"
            Yojson.Safe.Util.(member "query" result_json |> to_string);
          check string "fallback provider selected" "searxng"
            Yojson.Safe.Util.(member "engine" result_json |> to_string);
          check string "simulated provider url" "test://searxng"
            Yojson.Safe.Util.(member "search_url" result_json |> to_string);
          check int "result count" 1
            Yojson.Safe.Util.(member "result_count" result_json |> to_int);
          match Yojson.Safe.Util.(member "results" result_json |> to_list) with
          | [ hit ] ->
            check string "hit title" "OCaml Eio runtime"
              Yojson.Safe.Util.(member "title" hit |> to_string);
            check string "snippet cleaned" "Fiber runtime evidence"
              Yojson.Safe.Util.(member "snippet" hit |> to_string)
          | _ -> fail "expected one web search hit"))

let test_model_visible_web_fetch_dispatches_to_misc_runtime () =
  with_exec_fixture ~always_allow:true "keeper_tool_dispatch_web_fetch"
    (fun ~config ~meta ~publication_recovery ~ctx_work ->
      let requested_url = "https://example.com/model-web-fetch" in
      let html =
        {|
<!doctype html>
<html>
  <head>
    <title>Alias Title &amp; More</title>
    <meta name="description" content="Alias description &amp; detail">
  </head>
  <body>
    <h1>Alias Fetch</h1>
    <p>Body <b>content</b> &amp; proof.</p>
  </body>
</html>|}
      in
      Masc.Tool_misc.with_web_fetch_http_get_for_test
        (fun ~timeout_sec ~headers ~max_response_bytes url ->
          check int "timeout forwarded" 7 timeout_sec;
          check int "max response bytes forwarded" 2_000_000 max_response_bytes;
          check string "url forwarded" requested_url url;
          check bool "user agent header present" true
            (List.exists
               (fun (key, value) ->
                 String.equal key "User-Agent"
                 && String_util.contains_substring value "MASC-FetchWeb")
               headers);
          Ok (Some 200, html))
        (fun () ->
          let result =
            KET.execute_keeper_tool_call_with_outcome
              ~config
              ~meta
              ~publication_recovery
              ~ctx_work
              ~name:"WebFetch"
              ~input:
                (`Assoc
                  [
                    ("url", `String requested_url);
                    ("timeout", `Int 7);
                    ("extractMode", `String "markdown");
                    ("maxChars", `Int 200);
                  ])
              ()
          in
          check string "web fetch alias outcome" "success"
            (outcome_label result.disposition);
          let json = parse_json result.raw_output in
          check string "status" "ok"
            Yojson.Safe.Util.(member "status" json |> to_string);
          check string "url" requested_url
            Yojson.Safe.Util.(member "url" json |> to_string);
          check int "http status" 200
            Yojson.Safe.Util.(member "http_status" json |> to_int);
          check string "extract mode" "markdown"
            Yojson.Safe.Util.(member "extract_mode" json |> to_string);
          check bool "not truncated" false
            Yojson.Safe.Util.(member "truncated" json |> to_bool);
          check string "title" "Alias Title & More"
            Yojson.Safe.Util.(member "title" json |> to_string);
          check string "description" "Alias description & detail"
            Yojson.Safe.Util.(member "description" json |> to_string);
          check bool "heading rendered as markdown" true
            (String_util.contains_substring
               Yojson.Safe.Util.(member "text" json |> to_string)
               "# Alias Fetch");
          check bool "body text cleaned" true
            (String_util.contains_substring
               Yojson.Safe.Util.(member "text" json |> to_string)
               "Body content & proof.")))

(* The agent-core lane builds its bundle from the descriptor registry, and the
   ask tools had none: a Keeper running in-process could not see masc_ask, and
   a call under that name died as unknown_tool. The descriptor projects the
   name; this proves the rest of the lane -- dispatch, the store's registered-
   Keeper guard, and the durable row -- carries it. *)
let test_model_visible_masc_ask_records_the_question () =
  with_exec_fixture "keeper_tool_dispatch_masc_ask"
    (fun ~config ~meta ~publication_recovery ~ctx_work ->
      let result =
        KET.execute_keeper_tool_call_with_outcome
          ~config
          ~meta
          ~publication_recovery
          ~ctx_work
          ~name:"masc_ask"
          ~input:
            (`Assoc
              [ ( "questions"
                , `List
                    [ `Assoc
                        [ "question_id", `String "q1"
                        ; "header", `String "deploy"
                        ; "prompt", `String "Roll forward or roll back?"
                        ; "mode", `String "single"
                        ; ( "choices"
                          , `List
                              [ `Assoc
                                  [ "choice_id", `String "c1"
                                  ; "label", `String "roll forward"
                                  ]
                              ; `Assoc
                                  [ "choice_id", `String "c2"
                                  ; "label", `String "roll back"
                                  ]
                              ] )
                        ]
                    ] )
              ; "context", `String "the release window closes tonight"
              ])
          ()
      in
      check string "masc_ask outcome" "success" (outcome_label result.disposition);
      let json = parse_json result.raw_output in
      check string "recorded under the asking keeper" meta.name
        Yojson.Safe.Util.(member "keeper_name" json |> to_string);
      check int "the reply says one question is open" 1
        Yojson.Safe.Util.(member "open_count" json |> to_int);
      match
        Masc.Keeper_ask_store.rows ~base_path:config.base_path ~keeper_name:meta.name
      with
      | [ _, (ask, resolution) ] ->
        check string "the store row names the keeper" meta.name
          ask.Masc.Keeper_ask.keeper_name;
        check bool "the row is still open" true
          (resolution = Masc.Keeper_ask.Open)
      | _ -> fail "expected exactly one recorded ask")

let test_public_masc_web_fetch_rejects_localhost_after_gate () =
  with_exec_fixture
    ~always_allow:true
    "keeper_tool_dispatch_web_fetch_reaches_localhost"
    (fun ~config ~meta ~publication_recovery ~ctx_work ->
      let fetch_calls = ref 0 in
      Masc.Tool_misc.with_web_fetch_http_get_for_test
        (fun ~timeout_sec:_ ~headers:_ ~max_response_bytes:_ url ->
          incr fetch_calls;
          check string "local url forwarded" "http://127.0.0.1:8935/health" url;
          Ok (Some 200, "healthy"))
        (fun () ->
          let result =
            KET.execute_keeper_tool_call_with_outcome
              ~config
              ~meta
              ~publication_recovery
              ~ctx_work
              ~name:"WebFetch"
              ~input:(`Assoc [ ("url", `String "http://127.0.0.1:8935/health") ])
              ()
          in
          check string "web fetch local outcome" "failure"
            (outcome_label result.disposition);
          check bool
            "localhost rejection is a workflow error"
            true
            (result.disposition = Tool_result.Failed Tool_result.Workflow_rejection);
          check bool
            "localhost rejection names the loopback boundary"
            true
            (String_util.contains_substring result.raw_output "loopback address");
          check int "localhost never reaches HTTP" 0 !fetch_calls))

let test_manual_gate_defers_web_tools_before_network () =
  with_exec_fixture "keeper_tool_dispatch_manual_web_gate"
    (fun ~config ~meta ~publication_recovery ~ctx_work ->
      (match
         Masc.Keeper_gate_mode.set
           config
           ~actor:"test"
           Masc.Keeper_gate_mode.Manual
       with
       | Ok _ -> ()
       | Error detail -> fail ("failed to select Manual Gate mode: " ^ detail));
      let fetch_calls = ref 0 in
      Masc.Tool_misc.with_web_search_simulation_for_test
        ~outcomes:
          [ ( "searxng"
            , `Hits [ "unexpected", "https://example.com", "unexpected" ] )
          ]
        (fun () ->
          Masc.Tool_misc.with_web_fetch_http_get_for_test
            (fun ~timeout_sec:_ ~headers:_ ~max_response_bytes:_ _url ->
              incr fetch_calls;
              Ok (Some 200, "unexpected"))
            (fun () ->
              let search =
                KET.execute_keeper_tool_call_with_outcome
                  ~config
                  ~meta
                  ~publication_recovery
                  ~ctx_work
                  ~name:"WebSearch"
                  ~input:(`Assoc [ "query", `String "manual gate" ])
                  ()
              in
              let fetch =
                KET.execute_keeper_tool_call_with_outcome
                  ~config
                  ~meta
                  ~publication_recovery
                  ~ctx_work
                  ~name:"WebFetch"
                  ~input:(`Assoc [ "url", `String "http://127.0.0.1:8935/health" ])
                  ()
              in
              List.iter
                (fun result ->
                   check string "Manual Gate outcome" "deferred"
                     (outcome_label result.KTE.disposition);
                   match result.KTE.disposition with
                   | Tool_result.Deferred () -> ()
                   | Tool_result.Completed () | Tool_result.Failed _ ->
                     fail "Manual Gate lost its canonical deferred disposition")
                [ search; fetch ];
              check int "Manual Gate executes no WebFetch callback" 0 !fetch_calls)))

let test_approved_web_search_grant_executes_exact_request () =
  with_exec_fixture "keeper_tool_dispatch_approved_web_search"
    (fun ~config ~meta ~publication_recovery ~ctx_work ->
      (match
         Masc.Keeper_gate_mode.set
           config
           ~actor:"test"
           Masc.Keeper_gate_mode.Manual
       with
       | Ok _ -> ()
       | Error detail -> fail ("failed to select Manual Gate mode: " ^ detail));
      let input = `Assoc [ "query", `String "hourly scheduled search" ] in
      let first =
        KET.execute_keeper_tool_call_with_outcome
          ~config
          ~meta
          ~publication_recovery
          ~ctx_work
          ~name:"WebSearch"
          ~input
          ()
      in
      (match first.disposition with
       | Tool_result.Deferred () -> ()
       | Tool_result.Completed () | Tool_result.Failed _ ->
         fail "approval-gated WebSearch did not defer before execution");
      let approval_id =
        match
          Masc.Keeper_approval_queue.list_pending_entries_for_workspace
            ~base_path:config.base_path
        with
        | Ok [ entry ] -> entry.id
        | Ok entries ->
          failf "expected one pending WebSearch approval, got %d" (List.length entries)
        | Error error ->
          fail (Masc.Keeper_approval_queue.storage_error_to_string error)
      in
      (match
         Masc.Keeper_approval_queue.resolve_with_policy
           ~base_path:config.base_path
           ~id:approval_id
           ~decision:Keeper_approval_queue_rules_types.Decision.Approve
           ~source:Keeper_approval_queue_rules_types.Auto_judge
           ()
       with
       | Ok _ -> ()
       | Error error ->
         fail (Masc.Keeper_approval_queue.resolve_error_to_string error));
      let resolution : Keeper_event_queue.hitl_resolution =
        { approval_id
        ; decision = Keeper_event_queue.Hitl_approved
        ; channel =
            Keeper_continuation_channel.unrouted
              "approved WebSearch test"
        }
      in
      let grant =
        match Masc.Keeper_gate.cycle_grant_of_resolution resolution with
        | Some grant -> grant
        | None -> fail "approved WebSearch resolution did not create a grant"
      in
      Masc.Tool_misc.with_web_search_simulation_for_test
        ~outcomes:
          [ ( "searxng"
            , `Hits
                [ ( "Scheduled result"
                  , "https://example.com/scheduled"
                  , "approved exact WebSearch"
                  )
                ] )
          ]
        (fun () ->
          let second =
            KET.execute_keeper_tool_call_with_outcome
              ~config
              ~meta
              ~publication_recovery
              ~ctx_work
              ~gate_grant:grant
              ~name:"WebSearch"
              ~input
              ()
          in
          check string "approved WebSearch executes" "success"
            (outcome_label second.disposition));
      match
        Masc.Keeper_approval_queue.approved_resolution_state
          ~base_path:config.base_path
          ~id:approval_id
      with
      | Ok Masc.Keeper_approval_queue.Resolution_consumed -> ()
      | Ok Masc.Keeper_approval_queue.Resolution_unconsumed ->
        fail "approved WebSearch did not consume its one-shot grant"
      | Error error ->
        fail (Masc.Keeper_approval_queue.grant_error_to_string error))

let test_approved_web_search_replays_without_model_resubmission () =
  with_exec_fixture "keeper_tool_dispatch_replayed_web_search"
    (fun ~config ~meta ~publication_recovery ~ctx_work ->
      (match
         Masc.Keeper_gate_mode.set
           config
           ~actor:"test"
           Masc.Keeper_gate_mode.Manual
       with
       | Ok _ -> ()
       | Error detail -> fail ("failed to select Manual Gate mode: " ^ detail));
      let input =
        `Assoc
          [ "query", `String "approved replay search"
          ; "limit", `Int 1
          ]
      in
      let deferred =
        KET.execute_keeper_tool_call_with_outcome
          ~config
          ~meta
          ~publication_recovery
          ~ctx_work
          ~name:"WebSearch"
          ~input
          ()
      in
      (match deferred.disposition with
       | Tool_result.Deferred () -> ()
       | Tool_result.Completed () | Tool_result.Failed _ ->
         fail "approval-gated WebSearch did not defer before replay");
      let approval_id =
        match
          Masc.Keeper_approval_queue.list_pending_entries_for_workspace
            ~base_path:config.base_path
        with
        | Ok [ entry ] -> entry.id
        | Ok entries ->
          failf
            "expected one pending replay approval, got %d"
            (List.length entries)
        | Error error ->
          fail (Masc.Keeper_approval_queue.storage_error_to_string error)
      in
      (match
         Masc.Keeper_approval_queue.resolve_with_policy
           ~base_path:config.base_path
           ~id:approval_id
           ~decision:Keeper_approval_queue_rules_types.Decision.Approve
           ~source:Keeper_approval_queue_rules_types.Auto_judge
           ()
       with
       | Ok _ -> ()
       | Error error ->
         fail (Masc.Keeper_approval_queue.resolve_error_to_string error));
      let resolution : Keeper_event_queue.hitl_resolution =
        { approval_id
        ; decision = Keeper_event_queue.Hitl_approved
        ; channel =
            Keeper_continuation_channel.unrouted
              "replayed WebSearch test"
        }
      in
      let grant =
        match Masc.Keeper_gate.cycle_grant_of_resolution resolution with
        | Some grant -> grant
        | None -> fail "approved replay resolution did not create a grant"
      in
      Masc.Tool_misc.with_web_search_simulation_for_test
        ~outcomes:
          [ ( "searxng"
            , `Hits
                [ ( "Replayed result"
                  , "https://example.com/replayed"
                  , "approved WebSearch replay"
                  )
                ] )
        ]
        (fun () ->
          let bundle =
            Masc.Keeper_tools_agent_core_bundle.For_testing.make_tool_bundle
              ~config
              ~meta
              ~publication_recovery
              ~ctx_snapshot:ctx_work
              ~hitl_resolution:resolution
              ()
          in
          Fun.protect
            ~finally:bundle.cleanup
            (fun () ->
               match bundle.gate_replay_delivery with
               | Some
                   { outcome =
                       Masc.Keeper_gate_replay.Applied
                         { operation = "network_read"
                         ; output_ref
                         ; journal =
                             Masc.Keeper_gate_replay.Replay_journal_recorded
                         }
                   ; _
                   } ->
                 let output =
                   fetch_artifact_exn
                     ~base_path:config.base_path
                     output_ref
                 in
                 check bool
                   "stored WebSearch effect executed"
                   true
                   (String_util.contains_substring output "Replayed result")
               | Some
                   { outcome = Masc.Keeper_gate_replay.Applied _; _ } ->
                 fail
                   "replayed WebSearch did not durably journal its exact result"
               | Some { outcome; _ } ->
                 failf
                   "stored WebSearch effect was not replayed: %s"
                   (Masc.Keeper_gate_replay.outcome_to_string outcome)
               | None ->
                 fail
                   "production tool bundle dropped the approved replay outcome"));
      (match
         Masc.Keeper_approval_queue.approved_resolution_state
           ~base_path:config.base_path
           ~id:approval_id
       with
       | Ok Masc.Keeper_approval_queue.Resolution_consumed -> ()
       | Ok Masc.Keeper_approval_queue.Resolution_unconsumed ->
         fail "replayed WebSearch did not consume its one-shot grant"
       | Error error ->
         fail (Masc.Keeper_approval_queue.grant_error_to_string error));
      (match
         Masc.Keeper_approval_queue.approved_resolution_delivery
           ~base_path:config.base_path
           ~id:approval_id
       with
       | Ok
           { state = Masc.Keeper_approval_queue.Resolution_consumed
           ; replay_outcome =
               Some (Masc.Keeper_approval_queue.Replay_applied output_ref)
           ; _
           } ->
         let replay_store = Tool_blob_store.create ~base_path:config.base_path in
         (match
            Tool_blob_store.fetch replay_store ~sha256:output_ref.sha256
          with
          | Ok (Some output) ->
            check bool
              "replayed WebSearch output survives behind the durable reference"
              true
              (String_util.contains_substring output "Replayed result")
          | Ok None -> fail "durable replay output artifact is missing"
          | Error error ->
            fail (Tool_blob_store.fetch_error_to_string error));
         let model_message =
           Masc.Keeper_gate_replay.user_message_with_hitl_resolution
             ~base_path:config.base_path
             ~user_message:"continue"
             (Some resolution)
         in
         let projected_message =
           project_replay_message_exn
             ~base_path:config.base_path
             model_message
         in
         let projected_evidence =
           projected_message
           |> String.split_on_char '\n'
           |> List.rev
           |> List.find (fun line -> not (String.equal (String.trim line) ""))
           |> Yojson.Safe.from_string
         in
         check bool
           "durable replay output stays outside the provider-only projection"
           false
           (String_util.contains_substring projected_message "Replayed result");
         (match
            projected_evidence
            |> Yojson.Safe.Util.member "untrusted_tool_output_ref"
            |> Tool_output.normalized_artifact_ref_of_json
          with
          | Tool_output.Decoded_normalized_artifact_ref decoded ->
            check string
              "provider-only projection keeps the durable replay identity"
              output_ref.sha256
              decoded.sha256
          | Tool_output.Not_normalized_artifact_ref ->
            fail "provider replay evidence lost its artifact reference"
          | Tool_output.Invalid_normalized_artifact_ref { detail } ->
            fail detail);
         check bool
           "model is forbidden to request the consumed operation again"
           true
           (String_util.contains_substring
              model_message.text
              "Do not request the approved operation again")
       | Ok _ -> fail "durable WebSearch replay result was missing"
       | Error error ->
         fail (Masc.Keeper_approval_queue.grant_error_to_string error));
      match
        Masc.Keeper_gate_replay.replay_approved_effect
          ~config
          ~meta
          ~publication_recovery
          ~turn_sandbox_factory:None
          ~grant
          ~approval_id
          ()
      with
      | Masc.Keeper_gate_replay.Applied
          { journal =
              Masc.Keeper_gate_replay.Replay_journal_already_recorded
          ; _
          } ->
        ()
      | outcome ->
        failf
          "consumed WebSearch did not reuse its durable outcome: %s"
          (Masc.Keeper_gate_replay.outcome_to_string outcome))

let test_durable_connector_replay_settles_terminal_turn () =
  with_exec_fixture "keeper_durable_connector_replay_terminal"
    (fun ~config ~meta ~publication_recovery ~ctx_work ->
       let input =
         `Assoc
           [ "connector", `String "discord"
           ; "channel_id", `String "D-approved"
           ; "content", `String "approved reply already delivered"
           ; "mention_user_ids", `List []
           ]
       in
       let approval_id =
         match
           Masc.Keeper_approval_queue.submit_pending
             ~keeper_name:meta.name
             ~tool_name:"connector_post"
             ~input
             ~base_path:config.base_path
             ()
         with
         | Ok submission -> submission.approval_id
         | Error error ->
           fail (Masc.Keeper_approval_queue.storage_error_to_string error)
       in
       (match
          Masc.Keeper_approval_queue.resolve_with_policy
            ~base_path:config.base_path
            ~id:approval_id
            ~decision:Keeper_approval_queue_rules_types.Decision.Approve
            ~source:Keeper_approval_queue_rules_types.Auto_judge
            ()
        with
        | Ok _ -> ()
        | Error error ->
          fail (Masc.Keeper_approval_queue.resolve_error_to_string error));
       (match
          Masc.Keeper_approval_queue.consume_approved_resolution
            ~base_path:config.base_path
            ~id:approval_id
            ~keeper_name:meta.name
            ~tool_name:"connector_post"
            ~input
        with
        | Ok (Masc.Keeper_approval_queue.Consumption_committed _)
        | Ok Masc.Keeper_approval_queue.Consumption_already_committed ->
          ()
        | Ok Masc.Keeper_approval_queue.Consumption_not_matching ->
          fail "exact connector approval did not match"
        | Error error ->
          fail (Masc.Keeper_approval_queue.grant_error_to_string error));
       let output_ref =
         Tool_blob_store.put_durable
           (Tool_blob_store.create ~base_path:config.base_path)
           ~bytes:(Masc.Keeper_surface_post.ok_json ~surface:"discord" ())
           ~mime:"application/json"
       in
       (match
          Masc.Keeper_approval_queue.record_consumed_resolution_replay
            ~base_path:config.base_path
            ~id:approval_id
            ~outcome:(Masc.Keeper_approval_queue.Replay_applied output_ref)
        with
        | Ok Masc.Keeper_approval_queue.Replay_recorded
        | Ok Masc.Keeper_approval_queue.Replay_already_recorded ->
          ()
        | Error error ->
          fail (Masc.Keeper_approval_queue.grant_error_to_string error));
       let resolution : Keeper_event_queue.hitl_resolution =
         { approval_id
         ; decision = Keeper_event_queue.Hitl_approved
         ; channel =
             Keeper_continuation_channel.unrouted
               "durable connector replay terminal test"
         }
       in
       let bundle =
         Masc.Keeper_tools_agent_core_bundle.For_testing.make_tool_bundle
           ~config
           ~meta
           ~publication_recovery
           ~ctx_snapshot:ctx_work
           ~hitl_resolution:resolution
           ()
       in
       Fun.protect ~finally:bundle.cleanup @@ fun () ->
       match bundle.terminal_effect_state () with
       | Masc.Keeper_tools_agent_core.Terminal_effect_completed
           (Masc.Keeper_tool_execution.Surface_post_completed
              (Masc.Keeper_surface_post.To_discord { channel_id })) ->
         check string
           "durable replay settles the exact approved target"
           "D-approved"
           channel_id
       | ( Masc.Keeper_tools_agent_core.Terminal_effect_open
         | Masc.Keeper_tools_agent_core.Deferred_tool_result
         | Masc.Keeper_tools_agent_core.External_effect_deferred
         | Masc.Keeper_tools_agent_core.Terminal_effect_completed _
         | Masc.Keeper_tools_agent_core.Terminal_effect_failed _ ) ->
         fail "durable connector replay remained eligible for visible delivery")

let approved_web_search_resolution
      ~config
      ~meta
      ~publication_recovery
      ~ctx_work
      ~tool_call_id
  =
  let input =
    `Assoc
      [ "query", `String ("repair exact search " ^ tool_call_id)
      ; "limit", `Int 1
      ]
  in
  let deferred =
    KET.execute_keeper_tool_call_with_outcome
      ~config
      ~meta
      ~publication_recovery
      ~ctx_work
      ~gate_context:(fun () ->
        { Masc.Keeper_gate.turn_id = Some 18
        ; snapshot = `Assoc []
        })
      ~name:"WebSearch"
      ~input
      ()
  in
  (match deferred.disposition with
   | Tool_result.Deferred () -> ()
   | Tool_result.Completed () | Tool_result.Failed _ ->
     fail "repair fixture WebSearch did not defer");
  let approval_id =
    match
      Masc.Keeper_approval_queue.list_pending_entries_for_workspace
        ~base_path:config.Workspace.base_path
    with
    | Ok [ entry ] -> entry.id
    | Ok entries ->
      failf "expected one repair approval, got %d" (List.length entries)
    | Error error ->
      fail (Masc.Keeper_approval_queue.storage_error_to_string error)
  in
  (match
     Masc.Keeper_approval_queue.resolve_with_policy
       ~base_path:config.base_path
       ~id:approval_id
       ~decision:Keeper_approval_queue_rules_types.Decision.Approve
       ~source:Keeper_approval_queue_rules_types.Auto_judge
       ()
   with
   | Ok _ -> ()
   | Error error ->
     fail (Masc.Keeper_approval_queue.resolve_error_to_string error));
  let resolution : Keeper_event_queue.hitl_resolution =
    { approval_id
    ; decision = Keeper_event_queue.Hitl_approved
    ; channel =
        Keeper_continuation_channel.unrouted "Gate replay repair test"
    }
  in
  input, approval_id, resolution
;;

let test_blob_failure_repairs_journal_without_second_effect () =
  with_exec_fixture "keeper_gate_replay_blob_repair"
    (fun ~config ~meta ~publication_recovery ~ctx_work ->
       (match
          Masc.Keeper_gate_mode.set
            config
            ~actor:"test"
            Masc.Keeper_gate_mode.Manual
        with
        | Ok _ -> ()
        | Error detail -> fail detail);
       let _, approval_id, resolution =
         approved_web_search_resolution
           ~config
           ~meta
           ~publication_recovery
           ~ctx_work
           ~tool_call_id:"web-search-blob-repair"
       in
       let grant () =
         match Masc.Keeper_gate.cycle_grant_of_resolution resolution with
         | Some grant -> grant
         | None -> fail "approved repair resolution did not create a grant"
       in
       let first =
         Masc.Tool_misc.with_web_search_simulation_for_test
           ~outcomes:
             [ ( "searxng"
               , `Hits
                   [ ( "Exactly once"
                     , "https://example.com/once"
                     , "single effect"
                     )
                   ] )
             ]
         @@ fun () ->
         Masc.Keeper_gate_replay.For_testing.with_replay_evidence_persister
           (fun ~base_path:_ _ -> Error "forced blob failure")
         @@ fun () ->
         Masc.Keeper_gate_replay.replay_approved_effect
           ~config
           ~meta
           ~publication_recovery
           ~turn_sandbox_factory:None
           ~grant:(grant ())
           ~approval_id
           ()
       in
       (match first with
        | Masc.Keeper_gate_replay.Repair_required
            { stage = Masc.Keeper_gate_replay.Evidence_storage; _ } ->
          ()
        | outcome ->
          failf
            "blob failure was terminalized: %s"
            (Masc.Keeper_gate_replay.outcome_to_string outcome));
       (match
          Masc.Keeper_approval_queue.approved_resolution_delivery
            ~base_path:config.base_path
            ~id:approval_id
        with
        | Ok
            { state = Masc.Keeper_approval_queue.Resolution_consumed
            ; replay_outcome = None
            ; _
            } ->
          ()
        | Ok _ -> fail "blob failure wrote a terminal replay placeholder"
        | Error error ->
          fail (Masc.Keeper_approval_queue.grant_error_to_string error));
       match
         Masc.Keeper_gate_replay.replay_approved_effect
           ~config
           ~meta
           ~publication_recovery
           ~turn_sandbox_factory:None
           ~grant:(grant ())
           ~approval_id
           ()
       with
       | Masc.Keeper_gate_replay.Applied
           { journal = Masc.Keeper_gate_replay.Replay_journal_recorded
           ; output_ref
           ; _
           } ->
         let output =
           fetch_artifact_exn
             ~base_path:config.base_path
             output_ref
         in
         check bool
           "journal-only repair persisted the exact prior outcome"
           true
           (String_util.contains_substring output "Exactly once")
       | outcome ->
         failf
           "in-memory journal-only repair failed: %s"
           (Masc.Keeper_gate_replay.outcome_to_string outcome))
;;

let test_journal_failure_retries_only_persistence () =
  with_exec_fixture "keeper_gate_replay_journal_repair"
    (fun ~config ~meta ~publication_recovery ~ctx_work ->
       (match
          Masc.Keeper_gate_mode.set
            config
            ~actor:"test"
            Masc.Keeper_gate_mode.Manual
        with
        | Ok _ -> ()
        | Error detail -> fail detail);
       let _, approval_id, resolution =
         approved_web_search_resolution
           ~config
           ~meta
           ~publication_recovery
           ~ctx_work
           ~tool_call_id:"web-search-journal-repair"
       in
       let grant () =
         match Masc.Keeper_gate.cycle_grant_of_resolution resolution with
         | Some grant -> grant
         | None ->
           fail "approved journal-repair resolution created no grant"
       in
       let replay_path =
         Masc.Keeper_approval_queue.For_testing.replay_results_store_path
           ~base_path:config.base_path
       in
       mkdir_p (Filename.dirname replay_path);
       Unix.mkdir replay_path 0o755;
       let first =
         Masc.Tool_misc.with_web_search_simulation_for_test
           ~outcomes:
             [ ( "searxng"
               , `Hits
                   [ ( "Journal once"
                     , "https://example.com/journal-once"
                     , "single effect before journal failure"
                     )
                   ] )
             ]
         @@ fun () ->
         Masc.Keeper_gate_replay.replay_approved_effect
           ~config
           ~meta
           ~publication_recovery
           ~turn_sandbox_factory:None
           ~grant:(grant ())
           ~approval_id
           ()
       in
       (match first with
        | Masc.Keeper_gate_replay.Repair_required
            { stage = Masc.Keeper_gate_replay.Replay_journal; _ } ->
          ()
       | outcome ->
         failf
           "journal failure entered provider flow: %s"
           (Masc.Keeper_gate_replay.outcome_to_string outcome));
       (match
          Masc.Keeper_approval_queue.approved_resolution_delivery
            ~base_path:config.base_path
            ~id:approval_id
        with
        | Ok
            { state = Masc.Keeper_approval_queue.Resolution_consumed
            ; replay_outcome = None
            ; _
            } ->
          ()
        | Ok _ ->
          fail "journal failure changed the exact approval state"
        | Error error ->
          failf
            "replay sidecar failure blocked the whole Gate store: %s"
            (Masc.Keeper_approval_queue.grant_error_to_string error));
       Unix.rmdir replay_path;
       match
         Masc.Keeper_gate_replay.replay_approved_effect
           ~config
           ~meta
           ~publication_recovery
           ~turn_sandbox_factory:None
           ~grant:(grant ())
           ~approval_id
           ()
       with
       | Masc.Keeper_gate_replay.Applied
           { journal = Masc.Keeper_gate_replay.Replay_journal_recorded; _ } ->
         ()
       | outcome ->
         failf
           "journal-only repair reran or lost the outcome: %s"
           (Masc.Keeper_gate_replay.outcome_to_string outcome))
;;

let test_unknown_effect_is_durable_and_not_replayed () =
  with_exec_fixture "keeper_gate_replay_unknown_effect"
    (fun ~config ~meta ~publication_recovery ~ctx_work ->
       (match
          Masc.Keeper_gate_mode.set
            config
            ~actor:"test"
            Masc.Keeper_gate_mode.Manual
        with
        | Ok _ -> ()
        | Error detail -> fail detail);
       let _, approval_id, resolution =
         approved_web_search_resolution
           ~config
           ~meta
           ~publication_recovery
           ~ctx_work
           ~tool_call_id:"web-search-failed-effect"
       in
       let grant () =
         match Masc.Keeper_gate.cycle_grant_of_resolution resolution with
         | Some grant -> grant
         | None ->
           fail "approved failed-effect resolution created no grant"
       in
       let first =
         Masc.Tool_misc.with_web_search_simulation_for_test
           ~outcomes:[ "searxng", `Error "forced exact failure" ]
         @@ fun () ->
         Masc.Keeper_gate_replay.replay_approved_effect
           ~config
           ~meta
           ~publication_recovery
           ~turn_sandbox_factory:None
           ~grant:(grant ())
           ~approval_id
           ()
       in
       (match first with
        | Masc.Keeper_gate_replay.Indeterminate
            { journal = Masc.Keeper_gate_replay.Replay_journal_recorded; _ } ->
          ()
        | outcome ->
          failf
            "unknown effect was not durably recorded: %s"
            (Masc.Keeper_gate_replay.outcome_to_string outcome));
       match
         Masc.Keeper_gate_replay.replay_approved_effect
           ~config
           ~meta
           ~publication_recovery
           ~turn_sandbox_factory:None
           ~grant:(grant ())
           ~approval_id
           ()
       with
       | Masc.Keeper_gate_replay.Indeterminate
           { journal =
               Masc.Keeper_gate_replay.Replay_journal_already_recorded
           ; _
           } ->
         ()
       | outcome ->
         failf
           "durable indeterminate effect was executed again: %s"
           (Masc.Keeper_gate_replay.outcome_to_string outcome))
;;

let test_consumed_without_outcome_is_terminal_indeterminate () =
  with_exec_fixture "keeper_gate_replay_unknown_restart"
    (fun ~config ~meta ~publication_recovery ~ctx_work ->
       (match
          Masc.Keeper_gate_mode.set
            config
            ~actor:"test"
            Masc.Keeper_gate_mode.Manual
        with
        | Ok _ -> ()
        | Error detail -> fail detail);
       let input, approval_id, resolution =
         approved_web_search_resolution
           ~config
           ~meta
           ~publication_recovery
           ~ctx_work
           ~tool_call_id:"web-search-crash-gap"
       in
       let grant =
         match Masc.Keeper_gate.cycle_grant_of_resolution resolution with
         | Some grant -> grant
         | None ->
           fail "approved crash-gap resolution did not create a grant"
       in
       let request : Masc.Keeper_gate.request =
         { keeper_name = meta.name
         ; operation = "network_read"
         ; input =
             `Assoc
               [ "capability", `String "web_search"
               ; "input", input
               ]
         ; base_path = config.base_path
         ; sandbox_profile = None
         ; causal_context = None
         ; task_id = None
         ; continuation_channel = None
         }
       in
       (match
          Masc.Keeper_gate.decide
            ~cycle_grant:grant
            ~keeper_always_allow:false
            request
        with
        | Masc.Keeper_gate.Allow _ -> ()
        | Masc.Keeper_gate.Deferred _ | Masc.Keeper_gate.Unavailable _ ->
          fail "crash-gap fixture did not consume its approval");
       let restarted_grant =
         match Masc.Keeper_gate.cycle_grant_of_resolution resolution with
         | Some grant -> grant
         | None ->
           fail "approved restart resolution did not create a grant"
       in
       let first =
         Masc.Keeper_gate_replay.replay_approved_effect
           ~config
           ~meta
           ~publication_recovery
           ~turn_sandbox_factory:None
           ~grant:restarted_grant
           ~approval_id
           ()
       in
       (match first with
        | Masc.Keeper_gate_replay.Indeterminate
            { journal = Masc.Keeper_gate_replay.Replay_journal_recorded
            ; _
            } ->
          ()
        | outcome ->
          failf
            "consumed outcome gap did not settle fail-closed: %s"
            (Masc.Keeper_gate_replay.outcome_to_string outcome));
       match
         Masc.Keeper_approval_queue.approved_resolution_delivery
           ~base_path:config.base_path
           ~id:approval_id
       with
       | Ok
           { state = Masc.Keeper_approval_queue.Resolution_consumed
           ; replay_outcome =
               Some (Masc.Keeper_approval_queue.Replay_indeterminate _)
           ; _
           } ->
         ()
       | Ok _ -> fail "restart gap did not persist its terminal uncertainty"
       | Error error ->
         fail (Masc.Keeper_approval_queue.grant_error_to_string error))
;;

let test_unsupported_approved_operation_retains_exact_model_issued_path () =
  with_exec_fixture "keeper_gate_replay_unsupported"
    (fun ~config ~meta ~publication_recovery ~ctx_work:_ ->
       (match
          Masc.Keeper_gate_mode.set
            config
            ~actor:"test"
            Masc.Keeper_gate_mode.Manual
        with
        | Ok _ -> ()
        | Error detail -> fail detail);
       let exact_tail =
         "UNSUPPORTED-BEGIN\n"
         ^ String.make (512 * 1024) 'x'
         ^ "\nUNSUPPORTED-END"
       in
       let request : Masc.Keeper_gate.request =
         { keeper_name = meta.name
         ; operation = "unreplayed_operation"
         ; input = `Assoc [ "message", `String exact_tail ]
         ; base_path = config.base_path
         ; sandbox_profile = None
         ; causal_context = None
         ; task_id = None
         ; continuation_channel = None
         }
       in
       let approval_id =
         match
           Masc.Keeper_gate.decide
             ~keeper_always_allow:false
             request
         with
         | Masc.Keeper_gate.Deferred { approval_id; _ } -> approval_id
         | Masc.Keeper_gate.Allow _ | Masc.Keeper_gate.Unavailable _ ->
           fail "unsupported replay fixture did not defer"
       in
       (match
          Masc.Keeper_approval_queue.resolve_with_policy
            ~base_path:config.base_path
            ~id:approval_id
            ~decision:Keeper_approval_queue_rules_types.Decision.Approve
            ~source:Keeper_approval_queue_rules_types.Auto_judge
            ()
        with
        | Ok _ -> ()
        | Error error ->
          fail (Masc.Keeper_approval_queue.resolve_error_to_string error));
       let resolution : Keeper_event_queue.hitl_resolution =
         { approval_id
         ; decision = Keeper_event_queue.Hitl_approved
         ; channel =
             Keeper_continuation_channel.unrouted
               "unsupported Gate replay test"
         }
       in
       let grant =
         match Masc.Keeper_gate.cycle_grant_of_resolution resolution with
         | Some grant -> grant
         | None -> fail "unsupported approval did not create a grant"
       in
       let outcome =
         Masc.Keeper_gate_replay.replay_approved_effect
           ~config
           ~meta
           ~publication_recovery
           ~turn_sandbox_factory:None
           ~grant
           ~approval_id
           ()
       in
       (match outcome with
        | Masc.Keeper_gate_replay.Not_applicable -> ()
        | outcome ->
          failf
            "unsupported approval did not retain its model-issued path: %s"
            (Masc.Keeper_gate_replay.outcome_to_string outcome));
       (match
          Masc.Keeper_approval_queue.approved_resolution_delivery
            ~base_path:config.base_path
            ~id:approval_id
        with
        | Ok
            { state = Masc.Keeper_approval_queue.Resolution_unconsumed
            ; replay_outcome = None
            ; _
            } ->
          ()
        | Ok _ -> fail "unsupported approval consumed its authorization"
        | Error error ->
          fail (Masc.Keeper_approval_queue.grant_error_to_string error));
       let model_message =
         Masc.Keeper_gate_replay.compose_model_message
           ~base_path:config.base_path
           ~user_message:"continue"
           ~hitl_resolution:(Some resolution)
           ~replay_delivery:(Some (approval_id, outcome))
       in
       let model_message = model_message.Masc.Keeper_gate_replay.text in
       check bool
         "unsupported exact input remains in the model-issued path"
         true
         (String_util.contains_substring model_message "UNSUPPORTED-END");
       check bool
         "unsupported approval does not invent operator repair"
         false
         (String_util.contains_substring model_message "Operator repair is required"))
;;

let workflow_rejection_message =
  "Invalid task state: Self-approval not allowed: verifier must be a different agent"

let test_tool_result_does_not_infer_task_fsm_rejections_from_message () =
  let result =
    Tool_result.error
      ~failure_class:Tool_result.Runtime_failure
      ~tool_name:"masc_transition"
      ~start_time:(Unix.gettimeofday ())
      workflow_rejection_message
  in
  match (Tool_result.failure_class result) with
  | Some Tool_result.Runtime_failure -> ()
  | Some cls ->
    fail
      (Printf.sprintf
         "expected runtime_failure, got %s"
         (Tool_result.tool_failure_class_to_string cls))
  | None -> fail "expected failure_class"

let test_manual_gate_defers_tool_execute_before_process () =
  with_exec_fixture
    "keeper_tool_dispatch_manual_execute_gate"
    (fun ~config ~meta ~publication_recovery ~ctx_work ->
      (match
         Masc.Keeper_gate_mode.set
           config
           ~actor:"test"
           Masc.Keeper_gate_mode.Manual
       with
       | Ok _ -> ()
       | Error detail -> fail ("failed to select Manual Gate mode: " ^ detail));
      let marker = playground_file ~config ~meta "must-not-execute" in
      let result =
        KET.execute_keeper_tool_call_with_outcome
          ~config
          ~meta
          ~publication_recovery
          ~ctx_work
          ~name:"tool_execute"
          ~input:
            (`Assoc
               [ "argv", `List [ `String "touch"; `String marker ]
               ; "cwd", `String (KES.keeper_playground_root ~config ~meta)
               ; "timeout_sec", `Float 5.0
               ])
          ()
      in
      (match result.KTE.disposition with
       | Tool_result.Deferred () -> ()
       | Tool_result.Completed () -> fail "Manual Gate executed tool_execute"
       | Tool_result.Failed _ -> fail "Manual Gate turned tool_execute into failure");
      let data = Option.value ~default:`Null result.KTE.data in
      check string
        "Gate decision remains typed domain evidence"
        "deferred"
        Yojson.Safe.Util.(data |> member "gate" |> member "decision" |> to_string);
      check bool "Manual Gate starts no process" false (Sys.file_exists marker))

let test_tool_execute_raw_cmd_requires_typed_shell_ir () =
  with_exec_fixture "tool_execute_raw_cmd_requires_typed_shell_ir"
    (fun ~config ~meta ~publication_recovery ~ctx_work ->
      let input =
        `Assoc
          [ ( "cmd"
            , `String "cat .masc/state/backlog.json 2>/dev/null | head -5" )
          ]
      in
      let run () =
        KET.Compatibility.execute_keeper_tool_call
          ~config ~meta ~publication_recovery ~ctx_work
          ~name:"tool_execute" ~input ()
      in
      let outputs = List.init 4 (fun _ -> run ()) in
      List.iter
        (fun raw ->
           let json = Yojson.Safe.from_string raw in
           check string "cmd is refused by the parser, which names script"
             "cmd is not a field of this tool; the shell form is named \
              script"
             Yojson.Safe.Util.(member "error" json |> to_string);
           check bool "typed marker" true
             Yojson.Safe.Util.(member "typed" json |> to_bool))
        outputs;
      match outputs with
      | first :: rest ->
        List.iter (check string "repeated failures stay byte-identical" first) rest
      | [] -> fail "expected dispatch outputs")

(* task-777: #29813 advertised [script] in the schema while a key pre-check
   in the dispatch refused any call that used it. The admission is the
   parser now, so a schema-conformant script call must reach execution. *)
let test_tool_execute_script_form_is_admitted_and_runs () =
  with_exec_fixture
    ~process:true
    ~always_allow:true
    "tool_execute_script_form_runs"
    (fun ~config ~meta ~publication_recovery ~ctx_work ->
      let input =
        `Assoc [ "script", `String "printf begin- && printf end" ]
      in
      let raw =
        KET.Compatibility.execute_keeper_tool_call
          ~config ~meta ~publication_recovery ~ctx_work
          ~name:"tool_execute" ~input ()
      in
      let json = Yojson.Safe.from_string raw in
      check bool "script form executes" true
        Yojson.Safe.Util.(member "ok" json |> to_bool);
      check string "the and-chain ran both commands" "begin-end"
        Yojson.Safe.Util.(member "output" json |> to_string))

let test_tool_execute_empty_input_names_all_three_forms () =
  with_exec_fixture "tool_execute_empty_input_names_forms"
    (fun ~config ~meta ~publication_recovery ~ctx_work ->
      let raw =
        KET.Compatibility.execute_keeper_tool_call
          ~config ~meta ~publication_recovery ~ctx_work
          ~name:"tool_execute" ~input:(`Assoc []) ()
      in
      let json = Yojson.Safe.from_string raw in
      check string "no-source refusal names every form"
        "$.argv, $.pipeline or $.script is required"
        Yojson.Safe.Util.(member "error" json |> to_string))

let keeper_delegate_input_schema () =
  match
    List.find_opt
      (fun (schema : Masc_domain.tool_schema) ->
        String.equal schema.name "masc_keeper_delegate")
      Masc.Keeper_schema.schemas
  with
  | Some schema -> schema.input_schema
  | None -> fail "masc_keeper_delegate schema missing"

let test_agent_core_handler_threads_eio_context_to_keeper_dispatch () =
  let dir = temp_dir "agent-core-handler-eio-context" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      let net = Eio.Stdenv.net env in
      let clock = Eio.Stdenv.clock env in
      let mono_clock = Eio.Stdenv.mono_clock env in
      Eio.Switch.run @@ fun root_sw ->
      Eio_context.with_test_env ~net ~clock ~mono_clock ~sw:root_sw @@ fun () ->
      Eio.Switch.run @@ fun turn_sw ->
      Eio_context.with_turn_switch turn_sw @@ fun () ->
      let config = Workspace.default_config dir in
      let meta = make_meta () in
      create_keeper_meta_exn ~sw:root_sw ~config meta;
      ignore (Masc.Keeper_registry.For_testing.register ~base_path:config.base_path meta.name meta);
      Masc_test_deps.with_publication_recovery_registry
        ~sw:root_sw
        ~fs:(Eio.Stdenv.fs env)
        ~registry_root:dir
        (fun publication_recovery_registry ->
      let publication_recovery =
        { Publication_availability.provider =
            Publication_availability.constant
              (Publication_availability.Available
                 publication_recovery_registry)
        ; keeper_name = meta.name
        }
      in
      let previous_dispatch = !(Masc.Keeper_dispatch_ref.dispatch) in
      let saw_turn_sw = Atomic.make false in
      let saw_clock = Atomic.make false in
      let saw_provider = Atomic.make false in
      let delegated_data =
        `Assoc [ "run_ref", `Assoc [ "run_id", `String "test-run" ] ]
      in
      Fun.protect
        ~finally:(fun () ->
          Masc.Keeper_dispatch_ref.dispatch := previous_dispatch;
          Masc.Keeper_registry.For_testing.unregister ~base_path:config.base_path meta.name)
        (fun () ->
          Masc.Keeper_dispatch_ref.dispatch :=
            (fun ~config:_ ~agent_name:_
                 ~publication_recovery_provider:observed_provider
                 ?sw ?clock ?proc_mgr:_ ?net:_ ?mcp_session_id:_
                 ?authorize_external_effect:_
                 ~name ~args:_ () ->
              check string "keeper dispatch tool" "masc_keeper_delegate" name;
              Atomic.set saw_turn_sw
                (match sw with Some sw -> sw == turn_sw | None -> false);
              Atomic.set saw_clock (Option.is_some clock);
              Atomic.set saw_provider
                (observed_provider == publication_recovery.provider);
              Some
                (Tool_result.make_ok
                   ~tool_name:name
                   ~start_time:0.0
                   ~data:delegated_data
                   ()));
          let handler =
            Masc.Keeper_tools_agent_core_handler.make_keeper_tool_handler_from_meta
              ~name:"masc_keeper_delegate"
              ~input_schema:(keeper_delegate_input_schema ())
              ~config
              ~meta
              ~publication_recovery
              ~ctx_snapshot:(make_ctx ())
              ()
          in
          let result =
            handler
              (`Assoc
                [ ( "target"
                  , `Assoc
                      [ "kind", `String "keeper"
                      ; "name", `String "keeper-target"
                      ] )
                ; "prompt", `String "hello"
                ])
          in
          check bool "handler succeeds" true (Tool_result.is_success result);
          check
            (testable Yojson.Safe.pp Yojson.Safe.equal)
            "handler preserves producer data without a second outcome envelope"
            delegated_data
            (Tool_result.data result);
          check bool "turn switch reaches keeper dispatch" true (Atomic.get saw_turn_sw);
          check bool "clock reaches keeper dispatch" true (Atomic.get saw_clock);
          check bool "live provider reaches keeper dispatch" true
            (Atomic.get saw_provider))))

let registered_dispatch_probe_tool = "test_keeper_registered_dispatch_probe"

let probe_input_schema =
  `Assoc [ ("type", `String "object"); ("properties", `Assoc []) ]

let register_probe_schema tool_name =
  Tool_dispatch.register_module_tag
    ~schemas:
      [ ({ name = tool_name
         ; description = "test registered dispatch probe"
         ; input_schema = probe_input_schema
         }
          : Masc_domain.tool_schema )
      ]
    ~tag:Tool_dispatch.Mod_misc

let register_registered_dispatch_probe () =
  register_probe_schema registered_dispatch_probe_tool;
  Tool_dispatch.register
    ~tool_name:registered_dispatch_probe_tool
    ~handler:(fun ~name ~args:_ ->
      tool_ok ~tool_name:name
        (Yojson.Safe.to_string
           (`Assoc
             [ ("ok", `Bool true)
             ; ("tool", `String name)
             ; ("route", `String "registered")
             ])))

let workflow_rejection_probe_tool = "test_keeper_workflow_rejection_probe"

let register_workflow_rejection_probe () =
  register_probe_schema workflow_rejection_probe_tool;
  Tool_dispatch.register
    ~tool_name:workflow_rejection_probe_tool
    ~handler:(fun ~name ~args:_ ->
      Tool_result.error
        ~failure_class:Tool_result.Workflow_rejection
        ~tool_name:name
        ~start_time:(Unix.gettimeofday ())
        workflow_rejection_message)

let register_typed_outcome_probe name make_result =
  register_probe_schema name;
  Tool_dispatch.register
    ~tool_name:name
    ~handler:(fun ~name ~args:_ -> make_result name)
;;

let execute_registered_probe ~fixture ~name ~make_result =
  register_typed_outcome_probe name make_result;
  with_exec_fixture fixture
    (fun ~config ~meta ~publication_recovery ~ctx_work ->
    KET.execute_keeper_tool_call_with_outcome
      ~config
      ~meta
      ~publication_recovery
      ~ctx_work
      ~name
      ~input:(`Assoc [])
      ())
;;

let test_success_payload_with_error_data_stays_success () =
  let raw = {|{"ok":true,"error":"diagnostic data only"}|} in
  let result =
    execute_registered_probe
      ~fixture:"keeper_typed_success_error_data"
      ~name:"test_keeper_typed_success_error_data"
      ~make_result:(fun name ->
        Tool_result.make_ok
          ~tool_name:name
          ~start_time:0.0
          ~data:(`String raw)
          ())
  in
  check string "producer success remains success" "success"
    (outcome_label result.disposition);
  check string "opaque success payload preserved" raw result.raw_output
;;

let test_malformed_json_looking_success_stays_success () =
  let raw = {|{"unterminated|} in
  let result =
    execute_registered_probe
      ~fixture:"keeper_typed_success_malformed_payload"
      ~name:"test_keeper_typed_success_malformed_payload"
      ~make_result:(fun name ->
        Tool_result.make_ok
          ~tool_name:name
          ~start_time:0.0
          ~data:(`String raw)
          ())
  in
  check string "producer success ignores payload syntax" "success"
    (outcome_label result.disposition);
  check string "malformed-looking payload preserved" raw result.raw_output
;;

let test_only_typed_producer_failure_is_failure () =
  let raw = {|{"ok":true,"result":"looks successful"}|} in
  let result =
    execute_registered_probe
      ~fixture:"keeper_typed_failure_success_payload"
      ~name:"test_keeper_typed_failure_success_payload"
      ~make_result:(fun name ->
        Tool_result.make_err
          ~tool_name:name
          ~class_:Tool_result.Workflow_rejection
          ~start_time:0.0
          ~data:(`String raw)
          raw)
  in
  check string "producer failure remains failure" "failure"
    (outcome_label result.disposition);
  check string "success-looking failure payload preserved" raw result.raw_output;
  (match result.disposition with
   | Tool_result.Failed class_ ->
     check string "typed failure class preserved" "workflow_rejection"
       (Tool_result.tool_failure_class_to_string class_)
   | Tool_result.Completed () -> fail "expected typed producer failure"
   | Tool_result.Deferred () -> fail "expected typed producer failure, got deferred")
;;

let test_registered_tool_dispatch_without_masc_prefix () =
  register_registered_dispatch_probe ();
  check bool "probe has no masc_ prefix" false
    (String.starts_with ~prefix:"masc_" registered_dispatch_probe_tool);
  with_exec_fixture "keeper_tool_dispatch_registered_dispatch"
    (fun ~config ~meta ~publication_recovery:_ ~ctx_work:_ ->
      match
        Masc.Keeper_tool_registered_runtime.handle_registered_tool_with_outcome
          ~config
          ~keeper_name:meta.name
          ~name:registered_dispatch_probe_tool
          ~args:(`Assoc [])
      with
      | None -> fail "expected registered keeper tool dispatch"
      | Some execution ->
        let json = Yojson.Safe.from_string execution.raw_output in
        check string "registered tool name" registered_dispatch_probe_tool
          Yojson.Safe.Util.(member "tool" json |> to_string);
        check string "registered route" "registered"
          Yojson.Safe.Util.(member "route" json |> to_string))

let test_registered_dispatch_preserves_workflow_failure_class () =
  register_workflow_rejection_probe ();
  with_exec_fixture "keeper_tool_dispatch_registered_workflow_rejection"
    (fun ~config ~meta ~publication_recovery:_ ~ctx_work:_ ->
      match
        Masc.Keeper_tool_registered_runtime.handle_registered_tool_with_outcome
          ~config
          ~keeper_name:meta.name
          ~name:workflow_rejection_probe_tool
          ~args:(`Assoc [])
      with
      | None -> fail "expected registered keeper tool dispatch"
      | Some execution ->
        (match execution.disposition with
         | Tool_result.Failed Tool_result.Workflow_rejection -> ()
         | Tool_result.Failed class_ ->
           fail
             ("unexpected failure class: "
              ^ Tool_result.tool_failure_class_to_string class_)
         | Tool_result.Completed () -> fail "expected typed failure"
         | Tool_result.Deferred () -> fail "expected typed failure, got deferred");
        check bool "error message preserved" true
          (String_util.contains_substring execution.raw_output "Self-approval"))

(* ── Agent Core descriptor execution mode ───────────────────────────

   WebSearch/WebFetch hit external rate-limited APIs. They must not be
   assigned an inferred execution mode merely because they are read-only. *)

let make_dummy_agent_core_tool name =
  Masc.Tool_bridge.agent_core_tool_of_masc
    ~name
    ~description:"descriptor probe"
    ~input_schema:
      (`Assoc
         [ "type", `String "object"
         ; "properties", `Assoc []
         ; "required", `List []
         ])
    (fun _ -> Tool_result.make_ok ~tool_name:name ~start_time:0.0 ~data:(`String "") ())
;;

let test_descriptor_route_miss_payload_is_typed_runtime_failure () =
  let descriptor =
    match KTD.descriptors_for_internal "tool_execute" with
    | [ descriptor ] -> descriptor
    | [] -> fail "missing tool_execute descriptor"
    | _ :: _ :: _ -> fail "duplicate tool_execute descriptors"
  in
  let payload =
    KET.For_testing.descriptor_route_invariant_payload
      ~tool_name:"Execute"
      descriptor
  in
  (match
     KET.For_testing.descriptor_route_kind ~descriptor ~output:None
   with
   | KET.For_testing.Invariant -> ()
   | KET.For_testing.Output | KET.For_testing.Registered_only ->
     fail "resolved descriptor without output must not reach registered fallback");
  check bool "descriptor route miss is not ok" false
    Yojson.Safe.Util.(member "ok" payload |> to_bool);
  check string
    "descriptor route miss has typed error"
    "keeper_tool_descriptor_route_invariant"
    Yojson.Safe.Util.(member "error" payload |> to_string);
  check string
    "descriptor route miss is a runtime failure"
    "runtime_failure"
    Yojson.Safe.Util.(member "failure_class" payload |> to_string);
  check string "descriptor identity is retained" "agent.execute"
    Yojson.Safe.Util.(member "descriptor_id" payload |> to_string);
  check string "executor identity is retained" "shell_ir"
    Yojson.Safe.Util.(member "executor" payload |> to_string);
  check string "runtime handler identity is retained" "tool_execute"
    Yojson.Safe.Util.(member "runtime_handler" payload |> to_string)
;;

let check_no_inferred_descriptor ~msg name =
  let tool = make_dummy_agent_core_tool name in
  match Agent_core.Tool.descriptor tool with
  | None -> ()
  | Some _ -> fail (Printf.sprintf "%s: inferred descriptor for %s" msg name)
;;

let test_catalog_metadata_does_not_infer_agent_core_descriptors () =
  List.iter
    (fun name -> check_no_inferred_descriptor ~msg:"generic bridge" name)
    [ "masc_web_search"; "masc_web_fetch"; "tool_read_file"; "tool_search_files" ]
;;

let find_tool_by_name tools name =
  List.find_opt
    (fun (t : Agent_core.Tool.t) -> String.equal t.Agent_core.Tool.schema.Agent_core.Types.name name)
    tools
;;

let check_bundle_has_canonical_descriptor ~msg tools name =
  match find_tool_by_name tools name with
  | None -> fail (Printf.sprintf "%s: %s not in bundle" msg name)
  | Some t ->
    (match Agent_core.Tool.descriptor t with
     | Some _ -> ()
     | None -> fail (Printf.sprintf "%s: %s lost its canonical descriptor" msg name))
;;

let test_model_visible_tools_keep_canonical_agent_core_descriptors () =
  with_exec_fixture
    "model_visible_agent_core_descriptors"
    (fun ~config ~meta ~publication_recovery ~ctx_work:_ ->
       let tools =
         Masc.Keeper_tools_agent_core_bundle.For_testing.make_tools
           ~config
           ~meta
           ~publication_recovery
           ~ctx_snapshot:(make_ctx ())
           ()
       in
       List.iter
         (fun name ->
            check_bundle_has_canonical_descriptor ~msg:"model-visible" tools name)
         [ "WebSearch"; "WebFetch"; "Grep"; "Read" ])
;;

let terminal_surface_post tools =
  match find_tool_by_name tools "keeper_surface_post" with
  | Some tool -> tool
  | None -> fail "keeper_surface_post missing from Keeper tool bundle"
;;

let test_surface_post_bundle_names_reader_and_repeat_cost () =
  with_exec_fixture
    "surface_post_model_description"
    (fun ~config ~meta ~publication_recovery ~ctx_work ->
       let bundle =
         Masc.Keeper_tools_agent_core_bundle.For_testing.make_tool_bundle
           ~config
           ~meta
           ~publication_recovery
           ~ctx_snapshot:ctx_work
           ()
       in
       let description =
         (terminal_surface_post bundle.tools).Agent_core.Tool.schema.description
       in
       let help_description =
         match
           List.find_opt
             (fun (schema : Masc_domain.tool_schema) ->
                String.equal schema.name "keeper_surface_post")
             Tool_shard_types.surface_tools
         with
         | Some schema -> schema.description
         | None -> fail "keeper_surface_post missing from help schema projection"
       in
       check string
         "help and Agent Core projections use the same description"
         help_description
         description;
       List.iter
         (fun phrase ->
            check bool
              (Printf.sprintf "projected description contains %S" phrase)
              true
              (String_util.contains_substring description phrase))
         [ "read by a person"
         ; "unchanged status reposted every cycle"
         ; "the turn ends without a post"
         ])
;;

let test_invalid_surface_post_input_stays_correction_capable () =
  with_exec_fixture
    ~bind_eio_context:true
    "surface_post_invalid_input"
    (fun ~config ~meta ~publication_recovery ~ctx_work ->
       let bundle =
         Masc.Keeper_tools_agent_core_bundle.For_testing.make_tool_bundle
           ~config
           ~meta
           ~publication_recovery
           ~ctx_snapshot:ctx_work
           ()
       in
       let surface_post = terminal_surface_post bundle.tools in
       (match
          Agent_core.Tool.execute
            surface_post
            (`Assoc
               [ "surface", `String "dashboard"
               ; "content", `String ""
               ])
        with
        | Error _ -> ()
        | Ok _ -> fail "handler-level invalid terminal input unexpectedly succeeded");
       (match bundle.terminal_effect_state () with
        | Masc.Keeper_tools_agent_core.Terminal_effect_open -> ()
        | Masc.Keeper_tools_agent_core.Deferred_tool_result ->
          fail "invalid terminal input unexpectedly deferred a tool result"
        | Masc.Keeper_tools_agent_core.External_effect_deferred ->
          fail "invalid terminal input unexpectedly deferred an external effect"
        | Masc.Keeper_tools_agent_core.Terminal_effect_completed _ ->
          fail "invalid terminal input completed the terminal effect"
        | Masc.Keeper_tools_agent_core.Terminal_effect_failed _ ->
          fail "invalid terminal input poisoned the terminal effect");
       (match
          Agent_core.Tool.execute
            surface_post
            (`Assoc
               [ "surface", `String "dashboard"
               ; "content", `String "corrected terminal delivery"
               ])
        with
        | Ok _ -> ()
        | Error error ->
          failf "corrected terminal input failed: %s" error.Agent_core.Types.message);
       (match bundle.terminal_effect_state () with
        | Masc.Keeper_tools_agent_core.Terminal_effect_completed _ -> ()
        | Masc.Keeper_tools_agent_core.Terminal_effect_open ->
          fail "corrected terminal input left the terminal effect open"
        | Masc.Keeper_tools_agent_core.Deferred_tool_result ->
          fail "corrected terminal input unexpectedly deferred a tool result"
        | Masc.Keeper_tools_agent_core.External_effect_deferred ->
          fail "corrected terminal input unexpectedly deferred an external effect"
        | Masc.Keeper_tools_agent_core.Terminal_effect_failed _ ->
          fail "corrected terminal input failed the terminal effect");
       let chat_path =
         Filename.concat
           (Filename.concat
              (Common.masc_dir_from_base_path ~base_path:config.base_path)
              "keeper_chat")
           (meta.name ^ ".jsonl")
       in
       Unix.unlink chat_path;
       Unix.mkdir chat_path 0o755;
       (match
          Agent_core.Tool.execute
            surface_post
            (`Assoc
               [ "surface", `String "dashboard"
               ; "content", `String "later terminal failure"
               ])
        with
        | Error _ -> ()
        | Ok _ -> fail "forced later terminal failure unexpectedly succeeded");
       match bundle.terminal_effect_state () with
       | Masc.Keeper_tools_agent_core.Terminal_effect_failed _ -> ()
       | Masc.Keeper_tools_agent_core.Terminal_effect_open ->
         fail "later failure reopened the completed terminal effect"
       | Masc.Keeper_tools_agent_core.Deferred_tool_result ->
         fail "later failure unexpectedly became a generic defer"
       | Masc.Keeper_tools_agent_core.External_effect_deferred ->
         fail "later failure unexpectedly became an external defer"
        | Masc.Keeper_tools_agent_core.Terminal_effect_completed _ ->
         fail "later failure was hidden by the completed terminal effect")
;;

let with_openai_tool_call_server ?second_response ~tool_name ~tool_input f =
  let sw =
    match Eio_context.get_switch_opt () with
    | Some sw -> sw
    | None -> fail "test Eio switch missing"
  in
  let net =
    match Eio_context.get_net_opt () with
    | Some net -> net
    | None -> fail "test Eio net missing"
  in
  let provider_call_count = ref 0 in
  let tool_arguments = Yojson.Safe.to_string tool_input in
  let response_body =
    `Assoc
      [ "id", `String "surface-post-failure-tool-use"
      ; "object", `String "chat.completion"
      ; "created", `Int 0
      ; "model", `String "surface-post-failure-model"
      ; ( "choices"
        , `List
            [ `Assoc
                [ "index", `Int 0
                ; ( "message"
                  , `Assoc
                      [ "role", `String "assistant"
                      ; "content", `Null
                      ; ( "tool_calls"
                        , `List
                            [ `Assoc
                                [ "id", `String "surface-post-failure-call"
                                ; "type", `String "function"
                                ; ( "function"
                                  , `Assoc
                                      [ "name", `String tool_name
                                      ; "arguments", `String tool_arguments
                                      ] )
                                ] ] )
                      ] )
                ; "finish_reason", `String "tool_calls"
                ] ] )
      ; ( "usage"
        , `Assoc
            [ "prompt_tokens", `Int 1
            ; "completion_tokens", `Int 1
            ; "total_tokens", `Int 2
            ] )
      ]
    |> Yojson.Safe.to_string
  in
  let handler _conn _request body =
    ignore Eio.Buf_read.(of_flow ~max_size:max_int body |> take_all);
    incr provider_call_count;
    if !provider_call_count = 1
    then Cohttp_eio.Server.respond_string ~status:`OK ~body:response_body ()
    else (
      (* A caller that expects the turn to continue supplies the next answer;
         without one, a second call is the failure the test is looking for. *)
      match second_response with
      | Some body -> Cohttp_eio.Server.respond_string ~status:`OK ~body ()
      | None ->
        Cohttp_eio.Server.respond_string
          ~status:`Internal_server_error
          ~body:{|{"error":"terminal failure re-entered the provider"}|}
          ())
  in
  let socket =
    Eio.Net.listen
      net
      ~sw
      ~backlog:4
      ~reuse_addr:true
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port =
    match Eio.Net.listening_addr socket with
    | `Tcp (_, port) -> port
    | _ -> fail "loopback completion fixture did not expose a TCP port"
  in
  let server = Cohttp_eio.Server.make ~callback:handler () in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    Cohttp_eio.Server.run socket server ~on_error:(fun _ -> ()));
  let base_url = Printf.sprintf "http://127.0.0.1:%d" port in
  let result = f ~sw ~net ~base_url in
  result, !provider_call_count
;;

(* A Gate deferral parks the search and the turn keeps going: the model gets
   the deferred tool result and answers in the same turn. The parked call is
   replayed by the host once the approval resolves. *)
let test_deferred_web_search_keeps_the_turn_going () =
  with_exec_fixture
    ~bind_eio_context:true
    "deferred_web_search_yield"
    (fun ~config ~meta ~publication_recovery ~ctx_work ->
       (match
          Masc.Keeper_gate_mode.set
            config
            ~actor:"test"
            Masc.Keeper_gate_mode.Manual
        with
        | Ok _ -> ()
        | Error detail -> fail ("failed to select Manual Gate mode: " ^ detail));
       let bundle =
         Masc.Keeper_tools_agent_core_bundle.For_testing.make_tool_bundle
           ~config
           ~meta
           ~publication_recovery
           ~ctx_snapshot:ctx_work
           ()
       in
       let runtime_result, provider_call_count =
         with_openai_tool_call_server
           ~second_response:
             (Yojson.Safe.to_string
                (`Assoc
                    [ "id", `String "deferred-effect-followup"
                    ; "object", `String "chat.completion"
                    ; "created", `Int 0
                    ; "model", `String "deferred-effect-model"
                    ; ( "choices"
                      , `List
                          [ `Assoc
                              [ "index", `Int 0
                              ; ( "message"
                                , `Assoc
                                    [ "role", `String "assistant"
                                    ; ( "content"
                                      , `String "search parked; continuing" )
                                    ] )
                              ; "finish_reason", `String "stop"
                              ] ] )
                    ; ( "usage"
                      , `Assoc
                          [ "prompt_tokens", `Int 1
                          ; "completion_tokens", `Int 1
                          ; "total_tokens", `Int 2
                          ] )
                    ]))
           ~tool_name:"WebSearch"
           ~tool_input:
             (`Assoc [ "query", `String "hourly scheduled search" ])
         @@ fun ~sw ~net ~base_url ->
         let provider_cfg =
           Llm_provider.Provider_config.make
             ~kind:Llm_provider.Provider_config.OpenAI_compat
             ~model_id:"deferred-effect-model"
             ~base_url
             ~api_key:"test-key"
             ~request_path:"/chat/completions"
             ~tool_stream:false
             ()
         in
         let runtime_config =
           Runtime_agent.default_config
             ~name:"deferred-effect-runtime"
             ~provider_cfg
             ~system_prompt:"Search for the requested tool."
             ~tools:bundle.tools
         in
         Runtime_agent.run_blocks
           ~sw
           ~net
           ~config:runtime_config
           ~cooperative_yield_probe:(fun _boundary ->
             Masc.Keeper_agent_run.terminal_effect_boundary_decision
               (bundle.terminal_effect_state ()))
           [ Agent_core.Types.Text "search for the tool" ]
       in
       check int
         "the turn continued past the parked effect"
         2
         provider_call_count;
       (match
          Masc.Keeper_approval_queue.list_pending_entries_for_workspace
            ~base_path:config.base_path
        with
        | Ok [ { tool_name = "network_read"; _ } ] -> ()
        | Ok entries ->
          failf
            "deferred WebSearch produced %d unexpected approval rows"
            (List.length entries)
        | Error error ->
          fail
            (Masc.Keeper_approval_queue.storage_error_to_string error));
       (match runtime_result with
        | Ok { Runtime_agent.stop_reason = Runtime_agent.Completed; _ } -> ()
        | Ok result ->
          failf
            "parked effect returned stop_reason=%s"
            (Masc.Keeper_execution_receipt_types.stop_reason_to_string
               result.Runtime_agent.stop_reason)
        | Error error ->
          failf
            "parked effect failed instead of continuing: %s"
            (Agent_core.Error.to_string error));
       match bundle.terminal_effect_state () with
       | Masc.Keeper_tools_agent_core.External_effect_deferred -> ()
       | Masc.Keeper_tools_agent_core.Deferred_tool_result ->
         fail "Gate deferred effect became a generic tool defer"
       | Masc.Keeper_tools_agent_core.Terminal_effect_open ->
         fail "deferred effect was not observed at the tool boundary"
       | Masc.Keeper_tools_agent_core.Terminal_effect_completed _ ->
         fail "deferred effect became terminal completion"
       | Masc.Keeper_tools_agent_core.Terminal_effect_failed _ ->
         fail "deferred effect became terminal failure")
;;

let test_surface_post_append_failure_does_not_complete_terminal_effect () =
  with_exec_fixture
    ~bind_eio_context:true
    "surface_post_append_failure"
    (fun ~config ~meta ~publication_recovery ~ctx_work ->
       let chat_path =
         Filename.concat
           (Filename.concat
              (Common.masc_dir_from_base_path ~base_path:config.base_path)
              "keeper_chat")
           (meta.name ^ ".jsonl")
       in
       mkdir_p (Filename.dirname chat_path);
       Unix.mkdir chat_path 0o755;
       let bundle =
         Masc.Keeper_tools_agent_core_bundle.For_testing.make_tool_bundle
           ~config
           ~meta
           ~publication_recovery
           ~ctx_snapshot:ctx_work
           ()
       in
       let surface_post =
         match find_tool_by_name bundle.tools "keeper_surface_post" with
         | Some tool -> tool
         | None -> fail "keeper_surface_post missing from Keeper tool bundle"
       in
       let chat_broadcast_count = ref 0 in
       let subscriber_id = "surface-post-append-failure" in
       Masc.Sse.subscribe_external
         ~id:subscriber_id
         ~callback:(fun (ev : Masc.Sse.external_event) ->
            let event = ev.Masc.Sse.ext_frame in
           if String_util.contains_substring event "\"type\":\"keeper_chat_appended\""
           then incr chat_broadcast_count)
         ();
       Fun.protect
         ~finally:(fun () -> Masc.Sse.unsubscribe_external subscriber_id)
         (fun () ->
            let result =
              Agent_core.Tool.execute
                surface_post
                (`Assoc
                   [ "surface", `String "dashboard"
                   ; "content", `String "must remain undelivered"
                   ])
            in
            (match result with
             | Error error ->
               check bool
                 "append failure is an Agent Core runtime error"
                 true
                 (error.Agent_core.Types.error_class
                  = Some Agent_core.Types.Unknown);
               let error_detail =
                 Yojson.Safe.Util.
                   (parse_json error.Agent_core.Types.message
                    |> member "error"
                    |> to_string)
               in
               check bool
                 "raw append failure retains the exact full chat target"
                 true
                 (String_util.contains_substring error_detail chat_path)
             | Ok _ -> fail "durable dashboard append failure became Completed");
            check int
              "failed append emits no keeper chat broadcast"
              0
              !chat_broadcast_count;
            let terminal_state = bundle.terminal_effect_state () in
            (match terminal_state with
             | Masc.Keeper_tools_agent_core.Terminal_effect_failed failure ->
               check bool
                 "terminal failure retains the runtime failure class"
                 true
                 (failure.failure_class = Tool_result.Runtime_failure);
               check bool
                 "terminal failure retains unknown effect outcome"
                 true
                 (failure.effect_disposition
                  = Tool_result.Effect_outcome_unknown);
               check bool
                 "terminal failure retains the exact full chat target"
                 true
                 (String_util.contains_substring failure.diagnostic chat_path)
             | Masc.Keeper_tools_agent_core.Terminal_effect_open ->
               fail "failed surface delivery left the terminal effect open"
             | Masc.Keeper_tools_agent_core.Deferred_tool_result ->
               fail "failed surface delivery became a generic defer"
             | Masc.Keeper_tools_agent_core.External_effect_deferred ->
               fail "failed surface delivery became an external defer"
       | Masc.Keeper_tools_agent_core.Terminal_effect_completed _ ->
               fail "failed surface delivery set terminal completion");
            let first_terminal_failure =
              match terminal_state with
              | Masc.Keeper_tools_agent_core.Terminal_effect_failed failure -> failure
              | Masc.Keeper_tools_agent_core.Terminal_effect_open
              | Masc.Keeper_tools_agent_core.Deferred_tool_result
              | Masc.Keeper_tools_agent_core.External_effect_deferred
             | Masc.Keeper_tools_agent_core.Terminal_effect_completed _ ->
                fail "failed surface delivery lost its terminal failure"
            in
            Unix.rmdir chat_path;
            (match
               Agent_core.Tool.execute
                 surface_post
                 (`Assoc
                    [ "surface", `String "dashboard"
                    ; "content", `String "later successful delivery"
                    ])
             with
             | Ok _ -> ()
             | Error error ->
               failf
                 "later successful terminal call failed: %s"
                 error.Agent_core.Types.message);
            (match bundle.terminal_effect_state () with
             | Masc.Keeper_tools_agent_core.Terminal_effect_failed failure ->
               check bool
                 "first terminal failure is not overwritten"
                 true
                 (failure = first_terminal_failure)
             | Masc.Keeper_tools_agent_core.Terminal_effect_open ->
               fail "later success reopened the failed terminal effect"
             | Masc.Keeper_tools_agent_core.Deferred_tool_result ->
               fail "later success changed failure into a generic defer"
             | Masc.Keeper_tools_agent_core.External_effect_deferred ->
               fail "later success changed failure into an external defer"
             | Masc.Keeper_tools_agent_core.Terminal_effect_completed _ ->
               fail "later success overwrote the failed terminal effect");
            Unix.unlink chat_path;
            Unix.mkdir chat_path 0o755;
            let runtime_bundle =
              Masc.Keeper_tools_agent_core_bundle.For_testing.make_tool_bundle
                ~config
                ~meta
                ~publication_recovery
                ~ctx_snapshot:ctx_work
                ()
            in
            let broadcasts_before_runtime_failure = !chat_broadcast_count in
            let runtime_error, provider_call_count =
              with_openai_tool_call_server
                ~tool_name:"keeper_surface_post"
                ~tool_input:
                  (`Assoc
                     [ "surface", `String "dashboard"
                     ; "content", `String "must remain undelivered"
                     ])
              @@ fun ~sw ~net ~base_url ->
              let provider_cfg =
                Llm_provider.Provider_config.make
                  ~kind:Llm_provider.Provider_config.OpenAI_compat
                  ~model_id:"surface-post-failure-model"
                  ~base_url
                  ~api_key:"test-key"
                  ~request_path:"/chat/completions"
                  ~tool_stream:false
                  ()
              in
              let runtime_config =
                Runtime_agent.default_config
                  ~name:"surface-post-failure-runtime"
                  ~provider_cfg
                  ~system_prompt:"Deliver the requested dashboard reply."
                  ~tools:runtime_bundle.tools
              in
              match
                Runtime_agent.run_blocks
                  ~sw
                  ~net
                  ~config:runtime_config
                  ~cooperative_yield_probe:(fun _boundary ->
                    Masc.Keeper_agent_run.terminal_effect_boundary_decision
                      (runtime_bundle.terminal_effect_state ()))
                  [ Agent_core.Types.Text "deliver the dashboard reply" ]
              with
              | Error error -> error
              | Ok _ -> fail "terminal failure reached ordinary provider completion"
            in
            check int
              "terminal failure makes exactly one provider call"
              1
              provider_call_count;
            (match
               Keeper_internal_error.classify_masc_internal_error runtime_error
             with
             | Some
                 (Keeper_internal_error.Terminal_effect_failed
                    { failure_class = Tool_result.Runtime_failure
                    ; effect_disposition = Tool_result.Effect_outcome_unknown
                    ; diagnostic
                    }) ->
               check bool
                 "Runtime_agent error retains the exact full chat target"
                 true
                 (String_util.contains_substring diagnostic chat_path)
             | Some other ->
               failf
                 "Runtime_agent returned %s instead of terminal_effect_failed"
                 (Keeper_internal_error.kind_of_masc_internal_error other)
             | None -> fail "Runtime_agent flattened the typed terminal failure");
            (match runtime_bundle.terminal_effect_state () with
             | Masc.Keeper_tools_agent_core.Terminal_effect_failed failure ->
               check bool
                 "runtime terminal state retains Runtime_failure"
                 true
                 (failure.failure_class = Tool_result.Runtime_failure);
               check bool
                 "runtime terminal state retains unknown effect outcome"
                 true
                 (failure.effect_disposition
                  = Tool_result.Effect_outcome_unknown);
               check bool
                 "runtime terminal state retains the exact full chat target"
                 true
                 (String_util.contains_substring failure.diagnostic chat_path)
             | Masc.Keeper_tools_agent_core.Terminal_effect_open ->
               fail "runtime terminal failure was not recorded"
             | Masc.Keeper_tools_agent_core.Deferred_tool_result ->
               fail "runtime terminal failure became a generic defer"
             | Masc.Keeper_tools_agent_core.External_effect_deferred ->
               fail "runtime terminal failure became an external defer"
             | Masc.Keeper_tools_agent_core.Terminal_effect_completed _ ->
               fail "runtime terminal failure became completion");
            check int
              "runtime failure emits no keeper chat broadcast"
              broadcasts_before_runtime_failure
              !chat_broadcast_count;
            check bool
              "runtime terminal delivery failure is not auto-recoverable"
              false
              (Masc.Keeper_error_classify.is_auto_recoverable_turn_error
                 runtime_error);
            let exact_route =
              Keeper_runtime_failure_route.route_of_error
                ~boundary:Keeper_runtime_failure_route.Agent_core_execution
                runtime_error
            in
             (match exact_route with
             | Keeper_runtime_failure_route.Exhausted_visible_alive
                 { terminal =
                     Keeper_runtime_failure_route.Terminal_effect_runtime_failure
                 ; provenance = Keeper_runtime_failure_route.Masc_internal_error
                 ; _
                 } ->
               ()
             | _ -> fail "typed terminal failure did not reach its exact route");
            let transient_terminal_error =
              Keeper_internal_error.core_error_of_masc_internal_error
                (Keeper_internal_error.Terminal_effect_failed
                   { failure_class = Tool_result.Dependency_unavailable
                   ; effect_disposition = Tool_result.Effect_outcome_unknown
                   ; diagnostic = "unknown transient terminal effect"
                   })
            in
            (match
               Keeper_runtime_failure_route.route_of_error
                 ~boundary:Keeper_runtime_failure_route.Agent_core_execution
                 transient_terminal_error
             with
             | Keeper_runtime_failure_route.Exhausted_visible_alive
                 { terminal =
                     Keeper_runtime_failure_route.Terminal_effect_dependency_unavailable
                 ; provenance = Keeper_runtime_failure_route.Masc_internal_error
                 ; _
                 } ->
               ()
             | Keeper_runtime_failure_route.Retry_after_observed _ ->
               fail "unknown transient terminal effect was requeued"
             | _ -> fail "unknown transient terminal effect lost its exact route");
            (* A settlement assertion used to close this case: a failed
               terminal delivery must not Ack the source lease. #25969 replaced
               claim/settle with peek/ack, so nothing computes a settlement and
               "do not acknowledge" is expressed by not calling [ack_pending].
               The exact-route assertions above still cover the classification
               this case exists for. See #25980. *)
            ()))
;;

let composition_node_id value =
  match Masc.Keeper_tool_plan.Node_id.make value with
  | Ok id -> id
  | Error Masc.Keeper_tool_plan.Node_id.Empty -> fail "composition node id is empty"
;;

let composition_descriptor name =
  Masc.Keeper_tool_descriptor.all_descriptors ()
  |> List.find_opt (fun descriptor ->
    Masc.Keeper_tool_descriptor.keeper_model_names descriptor
    |> List.exists (String.equal name))
  |> function
  | Some descriptor -> descriptor
  | None -> fail ("composition descriptor missing: " ^ name)
;;

let composition_invocation ~completion =
  Agent_core.Tool_contract.Invocation.create
    ~tool_use_id:"composition-parent"
    ~turn:7
    ~schedule:
      { Agent_core.Tool_contract.planned_index = 0
      ; batch_index = 0
      ; batch_size = 1
      ; execution_mode = Agent_core.Tool_contract.Serial
      }
    ~completion
;;

let frozen_capability_surface () =
  let snapshot =
    Skill_catalog_snapshot.config_unreadable
      ~detail:"dispatch boundary test has no Skill sources"
  in
  Masc.Keeper_capability_surface.create
    ~skill_names:None
    ~global_skill_catalog:Masc.Keeper_skill_catalog.empty
    ~skill_inventory:(Masc.Keeper_skill_inventory.of_snapshot snapshot)
    ~task_skills:[]
;;

let test_frozen_surface_lists_and_searches_operator_only_tool () =
  let capability_surface = frozen_capability_surface () in
  let list_result =
    Masc.Keeper_tool_in_process_runtime.handle_tools_list
      ~capability_surface
      ~args:(`Assoc [])
      ()
  in
  check bool "complete inventory list completes" true
    (list_result.disposition = Tool_result.Completed ());
  let descriptor =
    Yojson.Safe.Util.(
      parse_json list_result.raw_output
      |> member "descriptor_surface"
      |> to_list)
    |> List.find_opt (fun row ->
      String.equal
        "masc_keeper_up"
        Yojson.Safe.Util.(row |> member "internal_name" |> to_string))
    |> function
    | Some row -> row
    | None -> fail "operator-only Tool is absent from keeper_tools_list"
  in
  check string "operator-only list availability"
    "not_model_invocable"
    Yojson.Safe.Util.(descriptor |> member "availability" |> to_string);
  check int "operator-only list has no active names" 0
    Yojson.Safe.Util.(descriptor |> member "active_names" |> to_list |> List.length);
  let search_result =
    Masc.Keeper_tool_in_process_runtime.handle_capability_search
      ~capability_surface
      ~args:(`Assoc [ "query", `String "masc_keeper_up" ])
      ()
  in
  check bool "operator-only inventory search completes" true
    (search_result.disposition = Tool_result.Completed ());
  let matches =
    match search_result.data with
    | Some data -> Yojson.Safe.Util.(data |> member "matches" |> to_list)
    | None -> fail "operator-only inventory search omitted typed data"
  in
  let found =
    List.exists
      (fun row ->
         let capability =
           Yojson.Safe.Util.(row |> member "candidate" |> member "capability")
         in
         String.equal
           "masc_keeper_up"
           Yojson.Safe.Util.(capability |> member "internal_name" |> to_string)
         && String.equal
              "not_model_invocable"
              Yojson.Safe.Util.(capability |> member "availability" |> to_string))
      matches
  in
  check bool "operator-only Tool search retains typed availability" true found
;;

let execution_data_exn label (result : KET.executed_tool_result) =
  match result.data with
  | Some data -> data
  | None -> fail (label ^ " omitted typed execution data")
;;

let check_frozen_surface_rejection label (result : KET.executed_tool_result) =
  check string (label ^ " outcome") "failure" (outcome_label result.disposition);
  check bool
    (label ^ " is a policy rejection")
    true
    (result.disposition = Tool_result.Failed Tool_result.Policy_rejection);
  check bool
    (label ^ " is proven pre-effect")
    true
    (result.failure_effect_disposition = Tool_result.Proven_pre_effect);
  let data = execution_data_exn label result in
  check string
    (label ^ " typed error")
    "tool_outside_frozen_capability_surface"
    Yojson.Safe.Util.(data |> member "error" |> to_string)
;;

(* [Read] used to stand here too: a Keeper could declare tool groups and leave
   it out, so dispatching it was a rejection. #31728 removed that declaration
   and the surface now holds every model-visible descriptor, so no capability
   surface can exclude [Read] and the half that asked for it is gone. What a
   surface still does not hold is a name registered only in [Tool_dispatch]
   with no descriptor behind it, which is what this covers. *)
let test_frozen_surface_direct_dispatch_rejects_registered_only_tool () =
  with_exec_fixture "frozen-surface-direct-excluded"
  @@ fun ~config ~meta ~publication_recovery ~ctx_work ->
  let capability_surface = frozen_capability_surface () in
  register_registered_dispatch_probe ();
  let registered_result =
    KET.execute_keeper_tool_call_for_capability_surface_with_outcome
      ~capability_surface
      ~config
      ~meta
      ~publication_recovery
      ~ctx_work
      ~name:registered_dispatch_probe_tool
      ~input:(`Assoc [])
      ()
  in
  check_frozen_surface_rejection
    "registered-only fallback"
    registered_result
;;

let test_frozen_surface_direct_dispatch_accepts_included_exact_descriptor () =
  with_exec_fixture "frozen-surface-direct-included"
  @@ fun ~config ~meta ~publication_recovery ~ctx_work ->
  let capability_surface = frozen_capability_surface () in
  let descriptor = composition_descriptor "keeper_time_now" in
  let result =
    KET.execute_keeper_tool_descriptor_for_capability_surface_with_outcome
      ~capability_surface
      ~config
      ~meta
      ~publication_recovery
      ~ctx_work
      ~descriptor
      ~input:(`Assoc [])
      ()
  in
  check string "included descriptor completes" "success"
    (outcome_label result.disposition);
  let name_result =
    KET.execute_keeper_tool_call_for_capability_surface_with_outcome
      ~capability_surface
      ~config
      ~meta
      ~publication_recovery
      ~ctx_work
      ~name:"keeper_time_now"
      ~input:(`Assoc [])
      ()
  in
  check string "included exposed name completes" "success"
    (outcome_label name_result.disposition)
;;

(* Direct descriptor dispatch is the only route that can present a descriptor
   the surface does not hold. A composition plan cannot: create canonicalizes
   every descriptor through [find_id], indexes nodes by [keeper_model_names]
   alone, and refuses a name with no model name as [Tool_off_keeper_surface]
   before execution starts. *)
let test_frozen_surface_rejects_same_id_counterfeit_descriptor () =
  with_exec_fixture "frozen-surface-counterfeit-descriptor"
  @@ fun ~config ~meta ~publication_recovery ~ctx_work ->
  let capability_surface = frozen_capability_surface () in
  let canonical = composition_descriptor "keeper_time_now" in
  let counterfeit =
    { canonical with description = canonical.description ^ " (counterfeit)" }
  in
  check string "counterfeit retains the registered id" canonical.id counterfeit.id;
  check bool "counterfeit is not canonical" false (counterfeit == canonical);
  let result =
    KET.execute_keeper_tool_descriptor_for_capability_surface_with_outcome
      ~capability_surface
      ~config
      ~meta
      ~publication_recovery
      ~ctx_work
      ~descriptor:counterfeit
      ~input:(`Assoc [])
      ()
  in
  check_frozen_surface_rejection "counterfeit descriptor" result
;;

let test_frozen_surface_production_bundle_executes_public_read () =
  with_exec_fixture "frozen-surface-production-read"
  @@ fun ~config ~meta ~publication_recovery ~ctx_work ->
  let playground = KES.keeper_default_write_root ~config ~meta in
  let relative_path = "frozen-bundle-read.txt" in
  let expected_content = "canonical frozen bundle content\n" in
  mkdir_p playground;
  write_file (Filename.concat playground relative_path) expected_content;
  let capability_surface = frozen_capability_surface () in
  let bundle =
    Masc.Keeper_tools_agent_core_bundle.make_tool_bundle_for_capability_surface
      ~config
      ~meta
      ~publication_recovery
      ~ctx_snapshot:ctx_work
      ~capability_surface
      ()
  in
  Fun.protect
    ~finally:bundle.cleanup
    (fun () ->
       let read_tool =
         match find_tool_by_name bundle.tools "Read" with
         | Some tool -> tool
         | None -> fail "production capability bundle omitted public Read"
       in
       match
         Agent_core.Tool.execute
           read_tool
           (`Assoc [ "file_path", `String relative_path; "limit", `Int 4096 ])
       with
       | Error error ->
         failf
           "production capability bundle Read failed: %s"
           error.Agent_core.Types.message
       | Ok output ->
         let payload = parse_json output.content in
         check string
           "production capability bundle returns fixture content"
           expected_content
           Yojson.Safe.Util.(payload |> member "content" |> to_string))
;;

let test_frozen_surface_name_dispatch_rejects_non_exposed_alias () =
  with_exec_fixture "frozen-surface-name-alias"
  @@ fun ~config ~meta ~publication_recovery ~ctx_work ->
  let capability_surface = frozen_capability_surface () in
  check bool
    "Read descriptor is active in the fixture"
    true
    (Masc.Keeper_capability_surface.descriptors capability_surface
     |> List.exists (fun descriptor ->
       Masc.Keeper_tool_descriptor.keeper_model_names descriptor
       |> List.exists (String.equal "Read")));
  let result =
    KET.execute_keeper_tool_call_for_capability_surface_with_outcome
      ~capability_surface
      ~config
      ~meta
      ~publication_recovery
      ~ctx_work
      ~name:"tool_read_file"
      ~input:(`Assoc [ "path", `String "outside.txt" ])
      ()
  in
  check_frozen_surface_rejection "non-exposed internal alias" result
;;

let test_tools_search_error_reaches_agent_core_as_typed_payload () =
  with_exec_fixture
    "tools-search-agent-core-error"
    (fun ~config ~meta ~publication_recovery ~ctx_work ->
       let tools =
         Masc.Keeper_tools_agent_core_bundle.For_testing.make_tools
           ~config
           ~meta
           ~publication_recovery
           ~ctx_snapshot:ctx_work
           ()
       in
       let tool =
         match find_tool_by_name tools "keeper_capability_search" with
         | Some tool -> tool
         | None -> fail "keeper_capability_search is absent from Agent Core bundle"
       in
       let reject input =
         match
           Agent_core.Tool.execute
             ~invocation:
               (composition_invocation
                  ~completion:Agent_core.Tool_contract.Continue_after_success)
             tool
             input
         with
         | Ok _ -> fail "invalid capability search unexpectedly completed"
         | Error error ->
           check
             (option bool)
             "policy rejection remains deterministic"
             (Some true)
             (Option.map
                (fun class_ -> class_ = Agent_core.Types.Deterministic)
                error.Agent_core.Types.error_class);
           parse_json error.Agent_core.Types.message
           |> Yojson.Safe.Util.member "masc.payload"
       in
       let empty = reject (`Assoc [ "query", `String "  " ]) in
       check string
         "Agent Core receives the typed search error kind"
         "frozen_surface_required"
         Yojson.Safe.Util.(empty |> member "error" |> member "kind" |> to_string);
       let wrong_type = reject (`Assoc [ "query", `Int 3 ]) in
       check string
         "descriptor validation reaches Agent Core as typed data"
         "invalid_args"
         Yojson.Safe.Util.(wrong_type |> member "reason" |> to_string))
;;

let one_node_clock_composition =
  {|[[compositions]]
name = "clock"
description = "Read the exact Keeper clock."
execution = "inline"

[[compositions.nodes]]
id = "time"
tool = "keeper_time_now"
[compositions.nodes.input]
kind = "literal"
value = {}
|}
;;

let off_surface_memory_composition =
  {|[[compositions]]
name = "off-surface-memory"
description = "Try one capability outside the turn surface."
execution = "inline"

[[compositions.nodes]]
id = "search"
tool = "keeper_memory_search"
[compositions.nodes.input]
kind = "literal"
value = { query = "must-not-run" }
|}
;;

let off_surface_memory_async_composition =
  {|[[compositions]]
name = "off-surface-memory-async"
description = "Try one async capability outside the turn surface."
execution = "async"

[[compositions.nodes]]
id = "search"
tool = "keeper_memory_search"
[compositions.nodes.input]
kind = "literal"
value = { query = "must-not-queue" }
|}
;;

(* #30220 made skills the only composition source: [make_tools] reads
   [Keeper_skill_catalog.composition_entries], not a bare catalog. The fixtures
   here are still composition TOML -- what changed is who carries it to the
   bundle -- so this wraps one in the skill document that now does. The
   directory has to match the frontmatter name, which has to match the
   composition's own name; that is what decides the [keeper_compose_*] tool. *)
let skill_catalog_of_composition ~name toml =
  let document =
    Printf.sprintf
      "---\nname: %s\ndescription: %s\n---\n\nComposition fixture.\n\n```toml composition\n%s```\n"
      name
      name
      toml
  in
  let config_text =
    {|[skills]
resource-read-max-bytes = 65536
[[skills.sources]]
id = "composition-fixture"
anchor = "base-path"
path = "skills"
access = "read-write"
|}
  in
  let skill_config =
    match Skill_source_config.parse_text config_text with
    | Ok config -> config
    | Error _ -> fail "composition Skill source fixture was rejected"
  in
  let source =
    match skill_config.Skill_source_config.sources with
    | [ source ] -> source
    | _ -> fail "composition Skill fixture must have one source"
  in
  let scan : Skill_catalog_snapshot.source_scan =
    { source =
        Skill_source_config.resolve
          ~base_path:"/workspace"
          ~user_home:None
          source
    ; observation =
        Skill_catalog_snapshot.Source_ready
          { resolved_path = "/workspace/skills"; candidates = 1 }
    ; candidates =
        [ Skill_catalog_snapshot.Candidate_document
            { directory = name; source_text = document }
        ]
    }
  in
  let snapshot =
    match Skill_catalog_snapshot.configured ~config:skill_config [ scan ] with
    | Ok snapshot -> snapshot
    | Error _ -> fail "composition Skill snapshot fixture was rejected"
  in
  match Masc.Keeper_skill_catalog.of_snapshot snapshot with
  | catalog, [] -> catalog
  | _, diagnostic :: _ ->
    failf
      "composition fixture %S was rejected as a skill: %s"
      name
      (Masc.Keeper_skill_catalog.error_to_string diagnostic.error)
;;

let one_node_terminal_composition =
  {|[[compositions]]
name = "surface"
execution = "inline"

[[compositions.nodes]]
id = "post"
tool = "keeper_surface_post"
[compositions.nodes.input]
kind = "literal"
value = { surface = "dashboard", content = "composition terminal" }
|}
;;

let invalid_clock_input_composition =
  {|[[compositions]]
name = "invalid-clock-input"
execution = "inline"

[[compositions.nodes]]
id = "time"
tool = "keeper_time_now"
[compositions.nodes.input]
kind = "literal"
value = { unsupported = true }
|}
;;

let post_effect_terminal_failure_composition =
  {|[[compositions]]
name = "write-then-invalid-post"
execution = "inline"

[[compositions.nodes]]
id = "write"
tool = "keeper_memory_write"
[compositions.nodes.input]
kind = "literal"
value = { title = "composition effect", content = "must execute exactly once" }

[[compositions.nodes]]
id = "post"
tool = "keeper_surface_post"
after = ["write"]
[compositions.nodes.input]
kind = "literal"
value = {}
|}
;;

let unknown_effect_terminal_failure_composition =
  {|[[compositions]]
name = "unknown-write-before-post"
execution = "inline"

[[compositions.nodes]]
id = "write"
tool = "keeper_memory_write"
[compositions.nodes.input]
kind = "literal"
value = { title = "composition unknown", content = "do not retry an uncertain write" }

[[compositions.nodes]]
id = "post"
tool = "keeper_surface_post"
after = ["write"]
[compositions.nodes.input]
kind = "literal"
value = { surface = "dashboard", content = "must not be reached" }
|}
;;

let write_then_unchanged_board_composition ~revision =
  Printf.sprintf
    {|[[compositions]]
name = "write-then-durable-wait"
execution = "inline"

[[compositions.nodes]]
id = "write"
tool = "keeper_memory_write"
[compositions.nodes.input]
kind = "literal"
value = { title = "composition before wait", content = "must execute exactly once before yielding" }

[[compositions.nodes]]
id = "wait"
tool = "masc_board_list"
after = ["write"]
[compositions.nodes.input]
kind = "literal"
value = { if_revision = %S }
|}
    revision
;;

let async_param_memory_composition =
  {|[[compositions]]
name = "memory-background"
execution = "async"

[[compositions.params]]
name = "query"
type = "string"
description = "The exact durable-memory query to run."

[[compositions.nodes]]
id = "search"
tool = "keeper_memory_search"
[compositions.nodes.input]
kind = "object"
[[compositions.nodes.input.fields]]
name = "query"
[compositions.nodes.input.fields.value]
kind = "param"
name = "query"
|}
;;

let shell_output_composition =
  {|[[compositions]]
name = "shell-output"
description = "Feed one typed Shell IR result into a later Keeper tool."
execution = "inline"

[[compositions.nodes]]
id = "emit"
tool = "Execute"
[compositions.nodes.input]
kind = "literal"
value = { argv = ["printf", "shell-composition-marker"] }

[[compositions.nodes]]
id = "search"
tool = "keeper_memory_search"
after = ["emit"]
[compositions.nodes.input]
kind = "object"
[[compositions.nodes.input.fields]]
name = "query"
[compositions.nodes.input.fields.value]
kind = "output"
node = "emit"
pointer = "/output"
|}
;;

let shell_artifact_composition () =
  let oversized_output =
    String.make (Masc.Tool_bridge.default_externalize_threshold_bytes + 1) 'x'
  in
  Printf.sprintf
    {|[[compositions]]
name = "shell-artifact"
description = "Feed one typed Shell IR artifact identity into a later Keeper tool."
execution = "inline"

[[compositions.nodes]]
id = "emit"
tool = "Execute"
[compositions.nodes.input]
kind = "literal"
value = { argv = ["printf", "%s"] }

[[compositions.nodes]]
id = "search"
tool = "keeper_memory_search"
after = ["emit"]
[compositions.nodes.input]
kind = "object"
[[compositions.nodes.input.fields]]
name = "query"
[compositions.nodes.input.fields.value]
kind = "output"
node = "emit"
pointer = "/output_artifact/_blob/sha256"
|}
    oversized_output
;;

let test_composition_catalog_materializes_and_executes_first_class_tool () =
  with_exec_fixture "composition-first-class-tool"
    (fun ~config ~meta ~publication_recovery ~ctx_work ->
       let skill_catalog =
         skill_catalog_of_composition ~name:"clock" one_node_clock_composition
       in
       let tools =
         Masc.Keeper_tools_agent_core_bundle.For_testing.make_tools
           ~config
           ~meta
           ~publication_recovery
           ~ctx_snapshot:ctx_work
           ~skill_catalog
           ()
       in
       let tool =
         match find_tool_by_name tools "keeper_compose_clock" with
         | Some tool -> tool
         | None -> fail "catalog entry was not materialized as an Agent-Core tool"
       in
       check string
         "catalog description reaches model-visible schema"
         "Read the exact Keeper clock."
         tool.Agent_core.Tool.schema.description;
       (match Agent_core.Tool.completion tool with
        | Agent_core.Tool_contract.Continue_after_success -> ()
        | Agent_core.Tool_contract.Terminal_after_success _ ->
          fail "ordinary composition was materialized as terminal");
       match
         Agent_core.Tool.execute
           ~invocation:
             (composition_invocation
                ~completion:Agent_core.Tool_contract.Continue_after_success)
           tool
           (`Assoc [])
       with
       | Error error ->
         failf "materialized composition failed: %s" error.Agent_core.Types.message
       | Ok output ->
         let payload = parse_json output.Agent_core.Types.content in
         check string
           "outer composition identity"
           "keeper_compose_clock"
           Yojson.Safe.Util.(member "composition_tool" payload |> to_string);
         (match Yojson.Safe.Util.member "actions" payload with
          | `List [ action ] ->
            check string
              "nested node identity"
              "time"
              Yojson.Safe.Util.(member "node_id" action |> to_string);
            check string
              "nested tool identity"
              "keeper_time_now"
              Yojson.Safe.Util.(member "tool_name" action |> to_string);
            check int
              "nested planned index"
              0
              Yojson.Safe.Util.(member "schedule" action |> member "planned_index" |> to_int);
            (match Yojson.Safe.Util.member "result" action with
             | `Assoc fields ->
               check bool
                 "nested result exposes typed data"
                 true
                 (List.mem_assoc "data" fields)
             | _ -> fail "nested action result lost typed result shape")
         | _ -> fail "composition did not expose its single settled action"))
;;

let test_compositions_share_closed_turn_descriptor_set () =
  with_exec_fixture "composition-closed-turn-descriptors"
    (fun ~config ~meta ~publication_recovery ~ctx_work ->
       let clock_descriptor = composition_descriptor "keeper_time_now" in
       let descriptors =
         [ { clock_descriptor with description = "forged descriptor description" } ]
       in
       let tools_for ~name composition =
         let skill_catalog = skill_catalog_of_composition ~name composition in
         Masc.Keeper_tools_agent_core_bundle.For_testing.make_tools_for_descriptors
           ~config
           ~meta
           ~publication_recovery
           ~ctx_snapshot:ctx_work
           ~descriptors
           ~skill_catalog
           ()
       in
       let inline_tools =
         tools_for
           ~name:"off-surface-memory"
           off_surface_memory_composition
       in
       let async_tools =
         tools_for
           ~name:"off-surface-memory-async"
           off_surface_memory_async_composition
       in
       let clock =
         match find_tool_by_name inline_tools "keeper_time_now" with
         | Some tool -> tool
         | None -> fail "closed descriptor set lost keeper_time_now"
       in
       check string
         "bundle resolves supplied descriptor to canonical authority"
         clock_descriptor.description
         clock.schema.description;
       let assert_deterministic_refusal
             ~expected_error_kind
             tools
             name
             input
         =
         let tool =
           match find_tool_by_name tools name with
           | Some tool -> tool
           | None -> failf "%s was not materialized" name
         in
         match
           Agent_core.Tool.execute
             ~invocation:
               (composition_invocation
                  ~completion:Agent_core.Tool_contract.Continue_after_success)
             tool
             input
         with
         | Ok _ -> failf "%s recovered a capability outside the turn surface" name
         | Error error ->
           check
             (option bool)
             (name ^ " returns a deterministic policy refusal")
             (Some true)
             (Option.map
                (fun error_class ->
                   error_class = Agent_core.Types.Deterministic)
                error.Agent_core.Types.error_class);
           let payload =
             parse_json error.Agent_core.Types.message
             |> Yojson.Safe.Util.member "masc.payload"
           in
           check string
             (name ^ " preserves exact outer identity")
             name
             Yojson.Safe.Util.(payload |> member "composition_tool" |> to_string);
           let typed_error = Yojson.Safe.Util.member "error" payload in
           check string
             (name ^ " preserves typed rejection kind")
             expected_error_kind
             Yojson.Safe.Util.(typed_error |> member "kind" |> to_string);
           check string
             (name ^ " preserves typed plan cause")
             "unknown_tool"
             Yojson.Safe.Util.(typed_error |> member "error" |> member "kind" |> to_string)
       in
       assert_deterministic_refusal
         ~expected_error_kind:"instantiated_plan_rejected"
         inline_tools
         "keeper_compose_off-surface-memory"
         (`Assoc []);
       assert_deterministic_refusal
         ~expected_error_kind:"instantiated_plan_rejected"
         async_tools
         "keeper_compose_off-surface-memory-async"
         (`Assoc []))
;;

let test_composition_feeds_typed_shell_ir_output_to_later_tool () =
  with_exec_fixture
    ~process:true
    ~always_allow:true
    "composition-shell-ir-output"
    (fun ~config ~meta ~publication_recovery ~ctx_work ->
       let skill_catalog =
         skill_catalog_of_composition ~name:"shell-output" shell_output_composition
       in
       let tools =
         Masc.Keeper_tools_agent_core_bundle.For_testing.make_tools
           ~config
           ~meta
           ~publication_recovery
           ~ctx_snapshot:ctx_work
           ~skill_catalog
           ()
       in
       let tool =
         match find_tool_by_name tools "keeper_compose_shell-output" with
         | Some tool -> tool
         | None -> fail "Shell IR composition was not materialized"
       in
       match
         Agent_core.Tool.execute
           ~invocation:
             (composition_invocation
                ~completion:Agent_core.Tool_contract.Continue_after_success)
           tool
           (`Assoc [])
       with
       | Error error -> fail error.Agent_core.Types.message
       | Ok output ->
         let payload = parse_json output.content in
         (match Yojson.Safe.Util.member "actions" payload with
          | `List [ emit; search ] ->
            check string
              "Shell IR node"
              "Execute"
              Yojson.Safe.Util.(member "tool_name" emit |> to_string);
            check bool
              "Shell IR typed result"
              true
              Yojson.Safe.Util.
                (member "result" emit |> member "data" |> member "typed" |> to_bool);
            check string
              "Shell IR exact output"
              "shell-composition-marker"
              Yojson.Safe.Util.
                (member "result" emit |> member "data" |> member "output" |> to_string);
            check string
              "later node receives typed Shell IR output"
              "shell-composition-marker"
              Yojson.Safe.Util.(member "input" search |> member "query" |> to_string)
          | _ -> fail "Shell IR composition did not settle both nodes in planned order"))
;;

let test_composition_externalizes_oversized_shell_ir_output () =
  with_exec_fixture
    ~process:true
    ~always_allow:true
    "composition-shell-ir-artifact"
    (fun ~config ~meta ~publication_recovery ~ctx_work ->
       Masc.Keeper_tool_call_log.reset_for_testing ();
       Masc.Keeper_tool_call_log.init ~base_path:config.base_path ();
       let turn_ctx_cell = Masc.Keeper_tool_call_log.create_turn_ctx_cell () in
       let skill_catalog =
         skill_catalog_of_composition
           ~name:"shell-artifact"
           (shell_artifact_composition ())
       in
       let tools =
         Masc.Keeper_tools_agent_core_bundle.For_testing.make_tools
           ~config
           ~meta
           ~publication_recovery
           ~ctx_snapshot:ctx_work
           ~skill_catalog
           ~turn_ctx_cell
           ()
       in
       let tool =
         match find_tool_by_name tools "keeper_compose_shell-artifact" with
         | Some tool -> tool
         | None -> fail "Shell IR artifact composition was not materialized"
       in
       match
         Agent_core.Tool.execute
           ~invocation:
             (composition_invocation
                ~completion:Agent_core.Tool_contract.Continue_after_success)
           tool
           (`Assoc [])
       with
       | Error error -> fail error.Agent_core.Types.message
       | Ok output ->
         let payload =
           structured_tool_output_exn
             ~base_path:config.base_path
             output.content
         in
         (match Yojson.Safe.Util.member "actions" payload with
          | `List [ emit; search ] ->
            let data = Yojson.Safe.Util.(member "result" emit |> member "data") in
            check
              bool
              "oversized output is not retained inline"
              true
              (Yojson.Safe.Util.member "output" data = `Null);
            let artifact_ref field =
              match
                Yojson.Safe.Util.member field data
                |> Tool_output.normalized_artifact_ref_of_json
              with
              | Tool_output.Decoded_normalized_artifact_ref reference -> reference
              | Tool_output.Not_normalized_artifact_ref ->
                failf
                  "oversized Shell IR output has no normalized %s reference"
                  field
              | Tool_output.Invalid_normalized_artifact_ref { detail } -> fail detail
            in
            let output_ref = artifact_ref "output_artifact" in
            let stdout_ref = artifact_ref "stdout_artifact" in
            let stderr_ref = artifact_ref "stderr_artifact" in
            check string "combined output equals stdout" output_ref.sha256 stdout_ref.sha256;
            check int "empty stderr is still explicit" 0 stderr_ref.bytes;
            let artifact =
              fetch_artifact_exn ~base_path:config.base_path output_ref
            in
            check
              int
              "artifact retains every output byte"
              (Masc.Tool_bridge.default_externalize_threshold_bytes + 1)
              (String.length artifact);
            let durable_root_present =
              Masc.Keeper_tool_call_log.read_recent
                ~keeper_name:meta.name
                ~n:10
                ()
              |> List.exists (fun row ->
                Safe_ops.json_string_opt "composition_node_id" row = Some "emit"
                &&
                match Yojson.Safe.Util.member "artifact_refs" row with
                | `List roots ->
                  List.exists
                    (fun root ->
                       let blob = Yojson.Safe.Util.member "_blob" root in
                       Safe_ops.json_string_opt "sha256" blob
                       = Some output_ref.sha256
                       && Safe_ops.json_string_opt "preview" blob = Some "")
                    roots
                | _ -> false)
            in
            check
              bool
              "durable action log owns a preview-free artifact root"
              true
              durable_root_present;
            let maintenance mode =
              match
                Tool_blob_maintenance.run ~base_path:config.base_path ~mode
              with
              | Ok report -> report
              | Error error ->
                fail (Tool_blob_maintenance.error_to_string error)
            in
            let observed = maintenance Tool_blob_maintenance.Observe_only in
            check
              bool
              "durable action evidence roots the stream artifacts"
              true
              (observed.live_references >= 2);
            ignore
              (maintenance Tool_blob_maintenance.Delete_previous_candidates);
            check
              string
              "maintenance preserves the referenced output"
              artifact
              (fetch_artifact_exn ~base_path:config.base_path output_ref);
            check
              string
              "later node receives the artifact identity"
              output_ref.sha256
              Yojson.Safe.Util.(member "input" search |> member "query" |> to_string)
          | _ ->
            fail
              "Shell IR artifact composition did not settle both nodes in planned order"))
;;

let test_direct_execute_artifact_manifest_survives_maintenance () =
  with_exec_fixture
    ~process:true
    ~always_allow:true
    "direct-shell-ir-artifact"
    (fun ~config ~meta ~publication_recovery ~ctx_work ->
       let execute =
         Masc.Keeper_tools_agent_core_bundle.For_testing.make_tools
           ~config
           ~meta
           ~publication_recovery
           ~ctx_snapshot:ctx_work
           ()
         |> List.find_opt (fun (tool : Agent_core.Tool.t) ->
           String.equal tool.schema.name "Execute")
         |> function
         | Some tool -> tool
         | None -> fail "direct Execute tool is absent"
       in
       let oversized =
         String.make (Masc.Tool_bridge.default_externalize_threshold_bytes + 1) 'd'
       in
       let output =
         match
           Agent_core.Tool.execute
             ~invocation:
               (composition_invocation
                  ~completion:Agent_core.Tool_contract.Continue_after_success)
             execute
             (`Assoc [ "argv", `List [ `String "printf"; `String oversized ] ])
         with
         | Ok output -> output.Agent_core.Types.content
         | Error error -> fail error.Agent_core.Types.message
       in
       let manifest_ref =
         match Tool_output.decode_from_agent_core output with
         | Tool_output.Decoded reference
           when String.equal reference.mime Tool_output.artifact_manifest_mime ->
           reference
         | Tool_output.Decoded _ -> fail "direct Execute returned a non-manifest marker"
         | Tool_output.Not_marker -> fail "direct Execute artifact result stayed inline"
         | Tool_output.Invalid_marker { detail } -> fail detail
       in
       let durable_checkpoint =
         Filename.concat
           (Common.masc_dir_from_base_path ~base_path:config.base_path)
           "keepers/direct-execute/checkpoint.json"
       in
       Fs_compat.mkdir_p (Filename.dirname durable_checkpoint);
       Fs_compat.save_file
         durable_checkpoint
         (Yojson.Safe.to_string (`Assoc [ "tool_result", `String output ]));
       let structured =
         structured_tool_output_exn ~base_path:config.base_path output
       in
       let output_ref =
         Yojson.Safe.Util.member "output_artifact" structured
         |> Tool_output.normalized_artifact_ref_of_json
         |> function
         | Tool_output.Decoded_normalized_artifact_ref reference -> reference
         | Tool_output.Not_normalized_artifact_ref ->
           fail "direct Execute manifest lost its child output reference"
         | Tool_output.Invalid_normalized_artifact_ref { detail } -> fail detail
       in
       let maintenance mode =
         match Tool_blob_maintenance.run ~base_path:config.base_path ~mode with
         | Ok report -> report
         | Error error -> fail (Tool_blob_maintenance.error_to_string error)
       in
       let observed = maintenance Tool_blob_maintenance.Observe_only in
       check bool
         "direct checkpoint roots manifest and child streams"
         true
         (observed.live_references >= 3);
       ignore (maintenance Tool_blob_maintenance.Delete_previous_candidates);
       check string
         "direct Execute child survives both maintenance passes"
         oversized
         (fetch_artifact_exn ~base_path:config.base_path output_ref);
       check bool
         "manifest itself survives both maintenance passes"
         true
         (match
            Tool_blob_store.fetch
              (Tool_blob_store.create ~base_path:config.base_path)
              ~sha256:manifest_ref.sha256
          with
          | Ok (Some _) -> true
          | Ok None | Error _ -> false))
;;

let test_direct_execute_post_effect_artifact_failure_closes_official_client_loop () =
  with_exec_fixture
    ~process:true
    ~always_allow:true
    "direct-shell-ir-post-effect-artifact-failure"
    (fun ~config ~meta ~publication_recovery ~ctx_work ->
       let bundle =
         Masc.Keeper_tools_agent_core_bundle.For_testing.make_tool_bundle
           ~config
           ~meta
           ~publication_recovery
           ~ctx_snapshot:ctx_work
           ()
       in
       Fun.protect
         ~finally:bundle.cleanup
         (fun () ->
            let blob_root =
              Tool_blob_store.create ~base_path:config.base_path
              |> Tool_blob_store.root_dir
            in
            Fs_compat.mkdir_p (Filename.dirname blob_root);
            Fs_compat.save_file blob_root "artifact persistence is blocked";
            let marker = Filename.concat config.base_path "execute-invocations" in
            let oversized =
              String.make
                (Masc.Tool_bridge.default_externalize_threshold_bytes + 1)
                'p'
            in
            let terminal_error = ref None in
            let projected =
              match
                Masc.Keeper_official_client_host.dynamic_tools
                  ~tool_approval:None
                  ~pre_tool_rejects:(ref [])
                  ~runtime_label:"test-official-client"
                  ~keeper_name:meta.name
                  ~turn_count:1
                  ~tools:bundle.tools
                  ~hooks:Agent_core.Hooks.empty
                  ~event_bus:None
                  ~context_injector:None
                  ~context:(Some (Agent_core.Context.create_sync ()))
                  ~terminal_effect_state:bundle.terminal_effect_state
                  ~terminal_error
                  ~raw_trace_run:None
                  ()
              with
              | Ok tools -> tools
              | Error error -> fail (Agent_core.Error.to_string error)
            in
            let execute =
              projected
              |> List.find_opt
                   (fun (tool : Masc.Keeper_official_client_host.dynamic_tool) ->
                      String.equal tool.name "Execute")
              |> function
              | Some tool -> tool
              | None -> fail "direct Execute tool was not projected"
            in
            let result =
              execute.call
                ~call_id:"direct-execute-post-effect-failure"
                (`Assoc
                   [ ( "argv"
                     , `List
                         [ `String "/bin/sh"
                         ; `String "-c"
                         ; `String "printf x >> \"$1\"; printf %s \"$2\""
                         ; `String "keeper-execute-test"
                         ; `String marker
                         ; `String oversized
                         ] )
                   ])
            in
            check bool "artifact persistence failure is visible" false result.success;
            check string
              "the process effect occurs exactly once before settlement"
              "x"
              (read_file marker);
            (match bundle.terminal_effect_state () with
             | Masc.Keeper_tools_agent_core.Terminal_effect_failed
                 { effect_disposition = Tool_result.Proven_post_effect; _ } ->
               ()
             | _ -> fail "ordinary Execute post-effect failure left bundle open");
            match result.abort_turn with
            | Some
                (Masc.Keeper_official_client_host.Terminal_tool_boundary
                  { tool_name = "Execute"
                  ; outcome =
                      Masc.Keeper_official_client_host.Terminal_failed
                        { effect_disposition = Tool_result.Proven_post_effect; _ }
                  }) ->
              ()
            | Some
                (Masc.Keeper_official_client_host.Terminal_tool_boundary _)
            | Some (Masc.Keeper_official_client_host.Repeated_tool_call _)
            | None ->
              fail "direct Execute post-effect failure remained provider-retryable"))
;;

let test_direct_pre_effect_and_readonly_failures_remain_correction_capable () =
  with_exec_fixture
    ~process:true
    ~always_allow:true
    "direct-pre-effect-correction"
    (fun ~config ~meta ~publication_recovery ~ctx_work ->
       let bundle =
         Masc.Keeper_tools_agent_core_bundle.For_testing.make_tool_bundle
           ~config
           ~meta
           ~publication_recovery
           ~ctx_snapshot:ctx_work
           ()
       in
       Fun.protect
         ~finally:bundle.cleanup
         (fun () ->
            let terminal_error = ref None in
            let projected =
              match
                Masc.Keeper_official_client_host.dynamic_tools
                  ~tool_approval:None
                  ~pre_tool_rejects:(ref [])
                  ~runtime_label:"test-official-client"
                  ~keeper_name:meta.name
                  ~turn_count:1
                  ~tools:bundle.tools
                  ~hooks:Agent_core.Hooks.empty
                  ~event_bus:None
                  ~context_injector:None
                  ~context:(Some (Agent_core.Context.create_sync ()))
                  ~terminal_effect_state:bundle.terminal_effect_state
                  ~terminal_error
                  ~raw_trace_run:None
                  ()
              with
              | Ok tools -> tools
              | Error error -> fail (Agent_core.Error.to_string error)
            in
            let call name input =
              let tool =
                projected
                |> List.find_opt
                     (fun (tool : Masc.Keeper_official_client_host.dynamic_tool) ->
                        String.equal tool.name name)
                |> function
                | Some tool -> tool
                | None -> failf "%s was not projected" name
              in
              tool.call ~call_id:("correction-" ^ name) input
            in
            let invalid_execute =
              call "Execute" (`Assoc [ "argv", `List [ `String "" ] ])
            in
            check bool "invalid Execute is a failure" false invalid_execute.success;
            check
              (option string)
              "pre-effect Execute failure keeps the turn open"
              None
              (Option.map
                 (fun _ -> "abort")
                 invalid_execute.abort_turn);
            let invalid_write =
              call
                "Write"
                (`Assoc
                   [ "file_path", `String ""
                   ; "content", `String "must not be written"
                   ])
            in
            check bool "invalid Write is a failure" false invalid_write.success;
            check
              (option string)
              "unaudited ordinary producer keeps its prior correction behavior"
              None
              (Option.map (fun _ -> "abort") invalid_write.abort_turn);
            let missing_artifact =
              call
                "keeper_artifact_read"
                (`Assoc [ "sha256", `String (String.make 64 '0') ])
            in
            check bool "missing artifact is a failure" false missing_artifact.success;
            check
              (option string)
              "read-only failure keeps the turn open"
              None
              (Option.map
                 (fun _ -> "abort")
                 missing_artifact.abort_turn);
            match bundle.terminal_effect_state () with
            | Masc.Keeper_tools_agent_core.Terminal_effect_open -> ()
            | _ -> fail "correction-capable failures poisoned terminal state"))
;;

let test_stale_spawn_handles_remain_correction_capable () =
  with_exec_fixture
    ~process:true
    ~always_allow:true
    ~bind_eio_context:true
    "stale-spawn-handle-correction"
    (fun ~config ~meta ~publication_recovery ~ctx_work ->
       let registry =
         Spawn_registry.create ~run:"current-turn" ~output_limit_bytes:(1 lsl 16)
         |> function
         | Some registry -> registry
         | None -> fail "valid spawn registry was rejected"
       in
       Spawn_turn_registry.with_turn_registry (Some registry) @@ fun () ->
       let bundle =
         Masc.Keeper_tools_agent_core_bundle.For_testing.make_tool_bundle
           ~config
           ~meta
           ~publication_recovery
           ~ctx_snapshot:ctx_work
           ()
       in
       Fun.protect
         ~finally:bundle.cleanup
         (fun () ->
            let terminal_error = ref None in
            let projected =
              match
                Masc.Keeper_official_client_host.dynamic_tools
                  ~tool_approval:None
                  ~pre_tool_rejects:(ref [])
                  ~runtime_label:"test-official-client"
                  ~keeper_name:meta.name
                  ~turn_count:1
                  ~tools:bundle.tools
                  ~hooks:Agent_core.Hooks.empty
                  ~event_bus:None
                  ~context_injector:None
                  ~context:(Some (Agent_core.Context.create_sync ()))
                  ~terminal_effect_state:bundle.terminal_effect_state
                  ~terminal_error
                  ~raw_trace_run:None
                  ()
              with
              | Ok tools -> tools
              | Error error -> fail (Agent_core.Error.to_string error)
            in
            let call name input =
              let tool =
                projected
                |> List.find_opt
                     (fun (tool : Masc.Keeper_official_client_host.dynamic_tool) ->
                        String.equal tool.name name)
                |> function
                | Some tool -> tool
                | None -> failf "%s was not projected" name
              in
              tool.call ~call_id:("stale-" ^ name) input
            in
            let stale_handle = "previous-turn-1" in
            let cases =
              [ ( "keeper_spawn_read"
                , `Assoc [ "handle", `String stale_handle ] )
              ; ( "keeper_spawn_wait"
                , `Assoc
                    [ "handle", `String stale_handle
                    ; "until", `String "exit"
                    ; "timeout_sec", `Float 1.
                    ] )
              ; ( "keeper_spawn_stop"
                , `Assoc [ "handle", `String stale_handle ] )
              ]
            in
            List.iter
              (fun (name, input) ->
                 let result = call name input in
                 check bool (name ^ " reports the stale handle") false result.success;
                 check
                   (option string)
                   (name ^ " keeps the provider loop correction-capable")
                   None
                   (Option.map (fun _ -> "abort") result.abort_turn))
              cases;
            match bundle.terminal_effect_state () with
            | Masc.Keeper_tools_agent_core.Terminal_effect_open -> ()
            | _ -> fail "stale handle lookup poisoned terminal state"))
;;

let test_composition_action_commit_advances_revision_before_refresh_event () =
  with_exec_fixture "composition-action-commit-refresh"
    (fun ~config ~meta ~publication_recovery ~ctx_work ->
       let subscriber_id = "composition-action-commit-refresh" in
       let frames = ref [] in
       Masc.Keeper_tool_call_log.reset_for_testing ();
       Masc.Keeper_tool_call_log.init ~base_path:config.base_path ();
       let revision_before = Masc.Keeper_tool_call_log.committed_revision () in
       Masc.Sse.subscribe_external
         ~id:subscriber_id
         ~callback:(fun event ->
           let frame = event.Masc.Sse.ext_frame in
           frames := frame :: !frames)
         ();
       Fun.protect
         ~finally:(fun () ->
           Masc.Sse.unsubscribe_external subscriber_id;
           Masc.Keeper_tool_call_log.reset_for_testing ())
         (fun () ->
            let skill_catalog =
              skill_catalog_of_composition ~name:"clock" one_node_clock_composition
            in
            let turn_ctx_cell = Masc.Keeper_tool_call_log.create_turn_ctx_cell () in
            let tool =
              Masc.Keeper_tools_agent_core_bundle.For_testing.make_tools
                ~config
                ~meta
                ~publication_recovery
                ~ctx_snapshot:ctx_work
                ~skill_catalog
                ~turn_ctx_cell
                ()
              |> List.find_opt (fun tool ->
                String.equal tool.Agent_core.Tool.schema.name "keeper_compose_clock")
              |> Option.get
            in
            (match
               Agent_core.Tool.execute
                 ~invocation:
                   (composition_invocation
                      ~completion:Agent_core.Tool_contract.Continue_after_success)
                 tool
                 (`Assoc [])
             with
             | Ok _ -> ()
             | Error error ->
               failf "materialized composition failed: %s" error.Agent_core.Types.message);
            let rows =
              Masc.Keeper_tool_call_log.read_recent ~keeper_name:meta.name ~n:2 ()
            in
            let committed_row =
              match
                List.find_opt
                  (fun row ->
                     Safe_ops.json_string_opt "composition_node_id" row = Some "time")
                  rows
              with
              | Some row ->
               check
                 (option string)
                 "committed nested row is immediately readable"
                 (Some "time")
                 (Safe_ops.json_string_opt "composition_node_id" row);
               check
                 (option string)
                 "committed nested row preserves the runtime model bucket"
                 (Some
                    (Keeper_hooks_agent_core_types.current_keeper_model meta))
                 (Safe_ops.json_string_opt "model" row);
               check bool
                 "committed nested row has canonical execution identity"
                 true
                 (match Safe_ops.json_string_opt "execution_id" row with
                  | Some value -> String.trim value <> ""
                  | None -> false);
               check bool
                 "committed nested row has producer byte count"
                 true
                 (match row with
                  | `Assoc fields -> List.mem_assoc "result_bytes" fields
                  | _ -> false);
               row
              | None -> fail "expected a synchronously committed nested action row"
            in
            let summary_row =
              match
                List.find_opt
                  (fun row ->
                     Safe_ops.json_string_opt "tool" row
                     = Some
                         Masc.Keeper_tool_composition_surface.composition_run_summary_tool_name)
                  rows
              with
              | Some row -> row
              | None -> fail "expected a durable composition run summary"
            in
            check
              (option bool)
              "run summary records terminal success"
              (Some true)
              (Safe_ops.json_bool_opt "success" summary_row);
            check bool
              "run summary records total duration"
              true
              (match Safe_ops.json_float_opt "duration_ms" summary_row with
               | Some duration_ms -> Float.compare duration_ms 0.0 >= 0
               | None -> false);
            check
              (option string)
              "run summary joins the node run"
              (Safe_ops.json_string_opt "composition_run_id" committed_row)
              (Safe_ops.json_string_opt "composition_run_id" summary_row);
            check
              int
              "durable revision advances before refresh"
              (revision_before + 2)
              (Masc.Keeper_tool_call_log.committed_revision ());
            let committed_refresh =
              List.find_map
                (fun frame ->
                   match Masc.Sse.data_payload_of_frame frame with
                   | Error Masc.Sse.Missing_data_payload -> None
                   | Ok payload ->
                     let json = Yojson.Safe.from_string payload in
                     if Safe_ops.json_string_opt "composition_node_id" json = Some "time"
                     then Some json
                     else None)
                !frames
            in
            let committed_refresh =
              match committed_refresh with
              | Some event -> event
              | None -> fail "post-commit refresh event was not broadcast"
            in
            let physical_tool_call_events =
              List.filter_map
                (fun frame ->
                   match Masc.Sse.data_payload_of_frame frame with
                   | Error Masc.Sse.Missing_data_payload -> None
                   | Ok payload ->
                     let json = Yojson.Safe.from_string payload in
                     if Safe_ops.json_string_opt "type" json = Some "keeper_tool_call"
                     then Some json
                     else None)
                !frames
            in
            check
              int
              "one physical tool execution event"
              1
              (List.length physical_tool_call_events);
            check
              (option string)
              "commit refresh has a distinct event type"
              (Some "keeper_tool_call_evidence_committed")
              (Safe_ops.json_string_opt "type" committed_refresh);
            check
              (option bool)
              "commit refresh carries node success"
              (Safe_ops.json_bool_opt "success" committed_row)
              (Safe_ops.json_bool_opt "success" committed_refresh);
            check
              (option (float 0.000_001))
              "commit refresh carries node duration"
              (Safe_ops.json_float_opt "duration_ms" committed_row)
              (Safe_ops.json_float_opt "duration_ms" committed_refresh);
            List.iter
              (fun field ->
                 check
                   (option string)
                   (field ^ " joins committed row and refresh event")
                   (Safe_ops.json_string_opt field committed_row)
                   (Safe_ops.json_string_opt field committed_refresh))
              [ "tool_use_id"; "composition_run_id" ]))
;;

let test_composition_telemetry_failure_does_not_change_execution () =
  with_exec_fixture "composition-telemetry-best-effort"
    (fun ~config ~meta ~publication_recovery ~ctx_work ->
       let frames = ref [] in
       let subscriber_id = "composition-telemetry-best-effort" in
       Masc.Keeper_tool_call_log.reset_for_testing ();
       Masc.Sse.subscribe_external
         ~id:subscriber_id
         ~callback:(fun event -> frames := event.Masc.Sse.ext_frame :: !frames)
         ();
       Fun.protect
         ~finally:(fun () ->
           Masc.Sse.unsubscribe_external subscriber_id;
           Masc.Keeper_tool_call_log.reset_for_testing ())
         (fun () ->
            let skill_catalog =
              skill_catalog_of_composition ~name:"clock" one_node_clock_composition
            in
            let turn_ctx_cell = Masc.Keeper_tool_call_log.create_turn_ctx_cell () in
            let tool =
              Masc.Keeper_tools_agent_core_bundle.For_testing.make_tools
                ~config
                ~meta
                ~publication_recovery
                ~ctx_snapshot:ctx_work
                ~skill_catalog
                ~turn_ctx_cell
                ()
              |> List.find_opt (fun tool ->
                String.equal tool.Agent_core.Tool.schema.name "keeper_compose_clock")
              |> Option.get
            in
            (match
               Agent_core.Tool.execute
                 ~invocation:
                   (composition_invocation
                      ~completion:Agent_core.Tool_contract.Continue_after_success)
                 tool
                 (`Assoc [])
             with
             | Ok _ -> ()
             | Error error ->
               failf
                 "telemetry outage changed composition execution: %s"
                 error.Agent_core.Types.message);
            check
              int
              "unavailable store does not fabricate a durable revision"
              0
              (Masc.Keeper_tool_call_log.committed_revision ());
            let committed_refreshes =
              List.filter_map
                (fun frame ->
                   match Masc.Sse.data_payload_of_frame frame with
                   | Error Masc.Sse.Missing_data_payload -> None
                   | Ok payload ->
                     let json = Yojson.Safe.from_string payload in
                     if
                       Safe_ops.json_string_opt "type" json
                       = Some "keeper_tool_call_evidence_committed"
                     then Some json
                     else None)
                !frames
            in
            check
              int
              "no durable-commit refresh is emitted without a durable commit"
              0
              (List.length committed_refreshes)))
;;

let test_terminal_composition_materializes_terminal_completion () =
  with_exec_fixture "composition-terminal-surface"
    (fun ~config ~meta ~publication_recovery ~ctx_work ->
       let skill_catalog =
         skill_catalog_of_composition ~name:"surface" one_node_terminal_composition
       in
       let tools =
         Masc.Keeper_tools_agent_core_bundle.For_testing.make_tools
           ~config
           ~meta
           ~publication_recovery
           ~ctx_snapshot:ctx_work
           ~skill_catalog
           ()
       in
       let tool =
         match find_tool_by_name tools "keeper_compose_surface" with
         | Some tool -> tool
         | None -> fail "terminal catalog entry was not materialized"
       in
       match Agent_core.Tool.completion tool with
       | Agent_core.Tool_contract.Terminal_after_success
           Agent_core.Tool_contract.Effect_outcome_unknown -> ()
       | Agent_core.Tool_contract.Continue_after_success
       | Agent_core.Tool_contract.Terminal_after_success _ ->
         fail "terminal composition lost its outer completion contract")
;;

let test_composition_plan_failure_exposes_typed_cause () =
  with_exec_fixture "composition-typed-plan-failure"
    (fun ~config ~meta ~publication_recovery ~ctx_work ->
       let skill_catalog =
         skill_catalog_of_composition ~name:"invalid-clock-input"
           invalid_clock_input_composition
       in
       let tool =
         Masc.Keeper_tools_agent_core_bundle.For_testing.make_tools
           ~config
           ~meta
           ~publication_recovery
           ~ctx_snapshot:ctx_work
           ~skill_catalog
           ()
         |> List.find_opt (fun (tool : Agent_core.Tool.t) ->
           String.equal tool.schema.name "keeper_compose_invalid-clock-input")
         |> function
         | Some tool -> tool
         | None -> fail "invalid-input composition was not materialized"
       in
       match
         Agent_core.Tool.execute
           ~invocation:
             (composition_invocation
                ~completion:Agent_core.Tool_contract.Continue_after_success)
           tool
           (`Assoc [])
       with
       | Ok _ -> fail "runtime-invalid composition input unexpectedly succeeded"
       | Error error ->
         let payload = parse_json error.Agent_core.Types.message in
         check string
           "failed outer composition identity"
           "keeper_compose_invalid-clock-input"
           Yojson.Safe.Util.(member "composition_tool" payload |> to_string);
         let cause = Yojson.Safe.Util.member "cause" payload in
         check string
           "typed executor cause"
           "plan_execution_failed"
           Yojson.Safe.Util.(member "kind" cause |> to_string);
         check string
           "typed plan failure"
           "input_validation_failed"
           Yojson.Safe.Util.(member "error" cause |> member "kind" |> to_string))
;;

let test_terminal_composition_post_effect_failure_closes_official_client_loop () =
  with_exec_fixture "composition-post-effect-terminal-failure"
    (fun ~config ~meta ~publication_recovery ~ctx_work ->
       (match
          Masc.Keeper_gate_mode.set
            config
            ~actor:"composition-test"
            Masc.Keeper_gate_mode.Always_allow
        with
        | Ok _ -> ()
        | Error detail -> fail ("failed to allow composition effect: " ^ detail));
       let skill_catalog =
         skill_catalog_of_composition ~name:"write-then-invalid-post" post_effect_terminal_failure_composition
       in
       let bundle =
         Masc.Keeper_tools_agent_core_bundle.For_testing.make_tool_bundle
           ~config
           ~meta
           ~publication_recovery
           ~ctx_snapshot:ctx_work
           ~skill_catalog
           ()
       in
       Fun.protect
         ~finally:bundle.cleanup
         (fun () ->
            let terminal_error = ref None in
            let projected =
              match
                Masc.Keeper_official_client_host.dynamic_tools
                  ~tool_approval:None
                  ~pre_tool_rejects:(ref [])
                  ~runtime_label:"test-official-client"
                  ~keeper_name:meta.name
                  ~turn_count:7
                  ~tools:bundle.tools
                  ~hooks:Agent_core.Hooks.empty
                  ~event_bus:None
                  ~context_injector:None
                  ~context:(Some (Agent_core.Context.create_sync ()))
                  ~terminal_effect_state:bundle.terminal_effect_state
                  ~terminal_error
                  ~raw_trace_run:None
                  ()
              with
              | Ok tools -> tools
              | Error error -> fail (Agent_core.Error.to_string error)
            in
            let tool =
              projected
              |> List.find_opt
                   (fun (tool : Masc.Keeper_official_client_host.dynamic_tool) ->
                      String.equal
                        tool.name
                        "keeper_compose_write-then-invalid-post")
              |> function
              | Some tool -> tool
              | None -> fail "terminal composition was not projected"
            in
            let result = tool.call ~call_id:"post-effect-composition" (`Assoc []) in
            check bool "terminal node failure is visible" false result.success;
            (match bundle.terminal_effect_state () with
             | Masc.Keeper_tools_agent_core.Terminal_effect_failed failure ->
               check string
                 "aggregate effect disposition"
                 "proven_post_effect"
                 (Tool_result.failure_effect_disposition_to_string
                    failure.effect_disposition)
             | _ -> fail "prior memory effect did not terminalize the bundle");
            let failure_payload = parse_json result.content in
            let cause = Yojson.Safe.Util.member "cause" failure_payload in
            check string
              "invalid node is rejected before dispatch"
              "plan_execution_failed"
              Yojson.Safe.Util.(member "kind" cause |> to_string);
            let plan_error = Yojson.Safe.Util.member "error" cause in
            check string
              "plan failure retains input validation kind"
              "input_validation_failed"
              Yojson.Safe.Util.(member "kind" plan_error |> to_string);
            check string
              "plan failure retains the typed policy rejection"
              "policy_rejection"
              Yojson.Safe.Util.
                (member "rejection" plan_error
                 |> member "failure_class"
                 |> to_string);
            match result.abort_turn with
            | Some
                (Masc.Keeper_official_client_host.Terminal_tool_boundary
                  { tool_name
                  ; outcome =
                      Masc.Keeper_official_client_host.Terminal_failed
                        { effect_disposition = Tool_result.Proven_post_effect; _ }
                  }) ->
              check string
                "official-client terminal tool"
                "keeper_compose_write-then-invalid-post"
                tool_name
            | Some
                (Masc.Keeper_official_client_host.Terminal_tool_boundary _)
            | Some (Masc.Keeper_official_client_host.Repeated_tool_call _)
            | None ->
              fail "official-client provider loop remained open after prior effect"))
;;

let test_terminal_composition_unknown_write_failure_closes_official_client_loop () =
  with_exec_fixture "composition-unknown-effect-terminal-failure"
    (fun ~config ~meta ~publication_recovery ~ctx_work ->
       (match
          Masc.Keeper_gate_mode.set
            config
            ~actor:"composition-test"
            Masc.Keeper_gate_mode.Always_allow
        with
        | Ok _ -> ()
        | Error detail -> fail ("failed to allow composition effect: " ^ detail));
       let keepers_dir =
         Config_dir_resolver.keepers_dir_for_base_path
           ~base_path:config.base_path
       in
       let snapshot_path =
         Masc.Keeper_memory_os_current.path_for_keepers_dir
           ~keepers_dir
           ~keeper_id:meta.name
       in
       (* A directory at the canonical snapshot path forces the writable
          producer to report its exact unknown-effect persistence failure. *)
       Fs_compat.mkdir_p snapshot_path;
       let skill_catalog =
         skill_catalog_of_composition ~name:"unknown-write-before-post" unknown_effect_terminal_failure_composition
       in
       let bundle =
         Masc.Keeper_tools_agent_core_bundle.For_testing.make_tool_bundle
           ~config
           ~meta
           ~publication_recovery
           ~ctx_snapshot:ctx_work
           ~skill_catalog
           ()
       in
       Fun.protect
         ~finally:bundle.cleanup
         (fun () ->
            let terminal_error = ref None in
            let projected =
              match
                Masc.Keeper_official_client_host.dynamic_tools
                  ~tool_approval:None
                  ~pre_tool_rejects:(ref [])
                  ~runtime_label:"test-official-client"
                  ~keeper_name:meta.name
                  ~turn_count:8
                  ~tools:bundle.tools
                  ~hooks:Agent_core.Hooks.empty
                  ~event_bus:None
                  ~context_injector:None
                  ~context:(Some (Agent_core.Context.create_sync ()))
                  ~terminal_effect_state:bundle.terminal_effect_state
                  ~terminal_error
                  ~raw_trace_run:None
                  ()
              with
              | Ok tools -> tools
              | Error error -> fail (Agent_core.Error.to_string error)
            in
            let tool =
              projected
              |> List.find_opt
                   (fun (tool : Masc.Keeper_official_client_host.dynamic_tool) ->
                      String.equal
                        tool.name
                        "keeper_compose_unknown-write-before-post")
              |> function
              | Some tool -> tool
              | None -> fail "unknown-effect composition was not projected"
            in
            let result = tool.call ~call_id:"unknown-effect-composition" (`Assoc []) in
            check bool "ordinary writable failure is visible" false result.success;
            (match bundle.terminal_effect_state () with
             | Masc.Keeper_tools_agent_core.Terminal_effect_failed failure ->
               check string
                 "producer-owned unknown disposition"
                 "effect_outcome_unknown"
                 (Tool_result.failure_effect_disposition_to_string
                    failure.effect_disposition)
             | _ -> fail "unknown writable failure did not terminalize the bundle");
            match result.abort_turn with
            | Some
                (Masc.Keeper_official_client_host.Terminal_tool_boundary
                  { tool_name
                  ; outcome =
                      Masc.Keeper_official_client_host.Terminal_failed
                        { effect_disposition = Tool_result.Effect_outcome_unknown; _ }
                  }) ->
              check string
                "official-client unknown-effect terminal tool"
                "keeper_compose_unknown-write-before-post"
                tool_name
            | Some
                (Masc.Keeper_official_client_host.Terminal_tool_boundary _)
            | Some (Masc.Keeper_official_client_host.Repeated_tool_call _)
            | None ->
              fail "official-client provider loop remained open after unknown effect"))
;;

let test_terminal_composition_post_effect_defer_closes_without_resume () =
  with_exec_fixture "composition-generic-defer-terminal-boundary"
    (fun ~config ~meta ~publication_recovery ~ctx_work ->
       (match
          Masc.Keeper_gate_mode.set
            config
            ~actor:"composition-test"
            Masc.Keeper_gate_mode.Always_allow
        with
        | Ok _ -> ()
        | Error detail -> fail ("failed to allow composition effect: " ^ detail));
       let direct_bundle =
         Masc.Keeper_tools_agent_core_bundle.For_testing.make_tool_bundle
           ~config
           ~meta
           ~publication_recovery
           ~ctx_snapshot:ctx_work
           ()
       in
       let revision =
         Fun.protect
           ~finally:direct_bundle.cleanup
           (fun () ->
              let board_list =
                match find_tool_by_name direct_bundle.tools "masc_board_list" with
                | Some tool -> tool
                | None -> fail "masc_board_list missing from Keeper tool bundle"
              in
              match Agent_core.Tool.execute board_list (`Assoc []) with
              | Error error -> fail error.Agent_core.Types.message
              | Ok output ->
                Yojson.Safe.Util.
                  (parse_json output.content |> member "revision" |> to_string))
       in
       let skill_catalog =
         skill_catalog_of_composition
           ~name:"write-then-durable-wait"
           (write_then_unchanged_board_composition ~revision)
       in
       let bundle =
         Masc.Keeper_tools_agent_core_bundle.For_testing.make_tool_bundle
           ~config
           ~meta
           ~publication_recovery
           ~ctx_snapshot:ctx_work
           ~skill_catalog
           ()
       in
       Fun.protect
         ~finally:bundle.cleanup
         (fun () ->
            let composition_tool =
              match
                find_tool_by_name
                  bundle.tools
                  "keeper_compose_write-then-durable-wait"
              with
              | Some tool -> tool
              | None -> fail "ordinary generic-deferred composition was not materialized"
            in
            (match Agent_core.Tool.completion composition_tool with
             | Agent_core.Tool_contract.Continue_after_success -> ()
             | Agent_core.Tool_contract.Terminal_after_success _ ->
               fail "composition without a terminal node became statically terminal");
            let terminal_error = ref None in
            let projected =
              match
                Masc.Keeper_official_client_host.dynamic_tools
                  ~tool_approval:None
                  ~pre_tool_rejects:(ref [])
                  ~runtime_label:"test-official-client"
                  ~keeper_name:meta.name
                  ~turn_count:9
                  ~tools:bundle.tools
                  ~hooks:Agent_core.Hooks.empty
                  ~event_bus:None
                  ~context_injector:None
                  ~context:(Some (Agent_core.Context.create_sync ()))
                  ~terminal_effect_state:bundle.terminal_effect_state
                  ~terminal_error
                  ~raw_trace_run:None
                  ()
              with
              | Ok tools -> tools
              | Error error -> fail (Agent_core.Error.to_string error)
            in
            let tool =
              projected
              |> List.find_opt
                   (fun (tool : Masc.Keeper_official_client_host.dynamic_tool) ->
                      String.equal
                        tool.name
                        "keeper_compose_write-then-durable-wait")
              |> function
              | Some tool -> tool
              | None -> fail "generic-deferred composition was not projected"
            in
            let result = tool.call ~call_id:"generic-deferred-composition" (`Assoc []) in
            check bool "generic-deferred composition is incomplete" false result.success;
            (match bundle.terminal_effect_state () with
             | Masc.Keeper_tools_agent_core.Terminal_effect_failed failure ->
               check string
                 "prior write prevents false resumability"
                 "proven_post_effect"
                 (Tool_result.failure_effect_disposition_to_string
                    failure.effect_disposition)
             | _ -> fail "post-effect defer did not terminalize the composition");
            let deferred_payload = parse_json result.content in
            check string
              "nested deferred node retains producer-owned kind"
              "generic_deferred"
              Yojson.Safe.Util.
                (member "cause" deferred_payload
                 |> member "node"
                 |> member "deferred_kind"
                 |> to_string);
            match result.abort_turn with
            | Some
                (Masc.Keeper_official_client_host.Terminal_tool_boundary
                  { tool_name
                  ; outcome =
                      Masc.Keeper_official_client_host.Terminal_failed
                        { effect_disposition = Tool_result.Proven_post_effect; _ }
                  }) ->
              check string
                "official-client post-effect defer terminal tool"
                "keeper_compose_write-then-durable-wait"
                tool_name
            | Some
                (Masc.Keeper_official_client_host.Terminal_tool_boundary _)
            | Some (Masc.Keeper_official_client_host.Repeated_tool_call _)
            | None ->
              fail "official-client provider loop remained retryable after post-effect defer"))
;;

let test_async_composition_binds_params_into_durable_status () =
  with_exec_fixture
    ~bind_eio_context:true
    "composition-async-param-durable-status"
    (fun ~config ~meta ~publication_recovery ~ctx_work ->
       let query = "async-param-worker-marker" in
       let skill_catalog =
         skill_catalog_of_composition
           ~name:"memory-background"
           async_param_memory_composition
       in
       let tools =
         Masc.Keeper_tools_agent_core_bundle.For_testing.make_tools
           ~config
           ~meta
           ~publication_recovery
           ~ctx_snapshot:ctx_work
           ~skill_catalog
           ()
       in
       let async_tool =
         match find_tool_by_name tools "keeper_compose_memory-background" with
         | Some tool -> tool
         | None -> fail "async composition tool was not materialized"
       in
       let status_tool =
         match find_tool_by_name tools "keeper_composition_status" with
         | Some tool -> tool
         | None -> fail "async composition status tool was not materialized"
       in
       (match Agent_core.Tool.execution_mode status_tool ~input:`Null with
        | Agent_core.Tool_contract.Concurrent -> ()
        | Agent_core.Tool_contract.Serial -> fail "status tool lost read-only concurrency");
       let request_id, composition_run_id =
         match
           Agent_core.Tool.execute
             ~invocation:
               (composition_invocation
                  ~completion:Agent_core.Tool_contract.Continue_after_success)
             async_tool
             (`Assoc [ "query", `String query ])
         with
         | Error error -> fail error.Agent_core.Types.message
         | Ok output ->
           let payload = parse_json output.content in
           check string
             "async acceptance mode"
             "async"
             Yojson.Safe.Util.(member "execution" payload |> to_string);
           ( Yojson.Safe.Util.(member "request_id" payload |> to_string)
           , Yojson.Safe.Util.(member "composition_run_id" payload |> to_string) )
       in
       check bool "async acceptance exposes run identity" true
         (String.trim composition_run_id <> "");
       let rec await_terminal () =
         match
           Masc.Keeper_msg_async.poll
             ~base_path:config.base_path
             ~caller:meta.name
             request_id
         with
         | Masc.Keeper_msg_async.Found
             ({ status = Masc.Keeper_msg_async.Done _; _ } as entry) ->
           entry
         | Masc.Keeper_msg_async.Found
             { status =
                 ( Masc.Keeper_msg_async.Queued
                 | Masc.Keeper_msg_async.Running
                 | Masc.Keeper_msg_async.Cancelling _ )
             ; _
             } ->
           Eio.Fiber.yield ();
           await_terminal ()
         | Masc.Keeper_msg_async.Found
             { status =
                 ( Masc.Keeper_msg_async.Lost _
                 | Masc.Keeper_msg_async.Cancelled _
                 | Masc.Keeper_msg_async.Persistence_failed _ )
             ; _
             } ->
           fail "async read-only composition did not complete"
         | Masc.Keeper_msg_async.Absent -> fail "durable async request disappeared"
         | Masc.Keeper_msg_async.Unreadable reason -> fail reason
         | Masc.Keeper_msg_async.Rejected _ -> fail "async request access was rejected"
       in
       let clock =
         match Eio_context.get_clock_opt () with
         | Some clock -> clock
         | None -> fail "async composition test lost its bound Eio clock"
       in
       ignore
         (Eio.Time.with_timeout_exn clock 5.0 await_terminal
           : Masc.Keeper_msg_async.entry);
       match
         Agent_core.Tool.execute
           ~invocation:
             (composition_invocation
                ~completion:Agent_core.Tool_contract.Continue_after_success)
           status_tool
           (`Assoc [ "request_id", `String request_id ])
       with
       | Error error -> fail error.Agent_core.Types.message
       | Ok output ->
         let payload = parse_json output.content in
         check string
           "durable terminal status"
           "done"
           Yojson.Safe.Util.(member "status" payload |> to_string);
         check string
           "durable structured composition result"
           "keeper_compose_memory-background"
           Yojson.Safe.Util.
             (member "result" payload |> member "composition_tool" |> to_string);
         match Yojson.Safe.Util.(member "result" payload |> member "actions") with
         | `List [ action ] ->
           check string
             "bound param reaches worker action input"
             query
             Yojson.Safe.Util.(member "input" action |> member "query" |> to_string);
           let memory_result =
             Yojson.Safe.Util.(member "result" action |> member "data" |> to_string)
             |> parse_json
           in
           check string
             "worker tool executes with bound query"
             query
             Yojson.Safe.Util.(member "query" memory_result |> to_string)
         | _ -> fail "durable async result lost its single worker action")
;;

let test_async_composition_status_preserves_artifact_manifest () =
  with_exec_fixture
    ~bind_eio_context:true
    "composition-async-artifact-status"
    (fun ~config ~meta ~publication_recovery ~ctx_work ->
       ignore publication_recovery;
       ignore ctx_work;
       let artifact_reference =
         Tool_blob_store.put_durable
           (Tool_blob_store.create ~base_path:config.base_path)
           ~bytes:"async artifact payload"
           ~mime:"text/plain"
       in
       let structured_data =
         `Assoc
           [ ( "output_artifact"
             , Tool_output.normalized_artifact_ref_to_json artifact_reference )
           ]
       in
       let background_sw =
         match Masc.Keeper_msg_async.server_background_switch () with
         | Ok sw -> sw
         | Error error ->
           fail
             (Masc.Keeper_msg_async.submit_error_to_json error
              |> Yojson.Safe.to_string)
       in
       let request_id =
         match Masc.Keeper_msg_async.submit
                 ~background_sw
                 ~base_path:config.base_path
                 ~caller:meta.name
                 ~keeper_name:meta.name
                 ~f:(fun _request_sw ->
                   Tool_result.make_ok
                     ~tool_name:"keeper_compose_artifact-fixture"
                     ~start_time:(Time_compat.now ())
                     ~data:structured_data
                     ())
                 ()
         with
         | Ok outcome -> outcome.request_id
         | Error error ->
           fail
             (Masc.Keeper_msg_async.submit_error_to_json error
              |> Yojson.Safe.to_string)
       in
       let rec await_terminal () =
         match
           Masc.Keeper_msg_async.poll
             ~base_path:config.base_path
             ~caller:meta.name
             request_id
         with
         | Masc.Keeper_msg_async.Found
             ({ status = Masc.Keeper_msg_async.Done _; _ } as entry) ->
           entry
         | Masc.Keeper_msg_async.Found
             { status =
                 ( Masc.Keeper_msg_async.Queued
                 | Masc.Keeper_msg_async.Running
                 | Masc.Keeper_msg_async.Cancelling _ )
             ; _
             } ->
           Eio.Fiber.yield ();
           await_terminal ()
         | Masc.Keeper_msg_async.Found _ ->
           fail "async artifact composition did not complete"
         | Masc.Keeper_msg_async.Absent -> fail "async artifact request disappeared"
         | Masc.Keeper_msg_async.Unreadable reason -> fail reason
         | Masc.Keeper_msg_async.Rejected _ ->
           fail "async artifact request access was rejected"
       in
       let clock =
         match Eio_context.get_clock_opt () with
         | Some clock -> clock
         | None -> fail "async artifact test lost its bound Eio clock"
       in
       ignore
         (Eio.Time.with_timeout_exn clock 5.0 await_terminal
           : Masc.Keeper_msg_async.entry);
       let status_result =
         Masc.Keeper_tool_composition_surface.For_testing.status_result
           ~config
           ~meta
           ~request_id
       in
       match Masc.Tool_bridge.to_agent_core_typed_result
               ~base_path:config.base_path
               status_result
       with
       | Error error -> fail error.Agent_core.Types.message
       | Ok output ->
         let payload =
           structured_tool_output_exn
             ~base_path:config.base_path
             output.content
         in
         check string "artifact status remains terminal" "done"
           Yojson.Safe.Util.(member "status" payload |> to_string);
         let artifact =
           Yojson.Safe.Util.
             (member "result" payload
              |> member "output_artifact")
         in
         match Tool_output.normalized_artifact_ref_of_json artifact with
         | Tool_output.Decoded_normalized_artifact_ref _ -> ()
         | Tool_output.Not_normalized_artifact_ref ->
           fail "async status dropped its normalized artifact reference"
         | Tool_output.Invalid_normalized_artifact_ref { detail } -> fail detail)
;;

let test_composition_runtime_uses_canonical_descriptor () =
  with_exec_fixture "composition-canonical-descriptor"
    (fun ~config ~meta ~publication_recovery ~ctx_work ->
       let canonical = composition_descriptor "keeper_time_now" in
       let supplied =
         { canonical with
           Masc.Keeper_tool_descriptor.execution =
             Masc.Keeper_tool_descriptor.Ordinary Masc.Keeper_tool_descriptor.Serial
         ; input_schema = `Assoc [ "type", `String "string" ]
         ; composable_output = Masc.Keeper_tool_descriptor.Opaque_output
         }
       in
       let node =
         Masc.Keeper_tool_plan.node
           ~id:(composition_node_id "time")
           ~tool_name:"keeper_time_now"
           ~input:(Masc.Keeper_tool_plan.Json_template.literal (`Assoc []))
           ()
       in
       let plan =
         match Masc.Keeper_tool_plan.create ~descriptors:[ supplied ] [ node ] with
         | Ok plan -> plan
         | Error _ -> fail "canonicalized composition plan was rejected"
       in
       match
         Masc.Keeper_tool_plan_executor.Compatibility.execute_keeper
           ~plan
           ~run_id:(Masc.Keeper_tool_plan.Run_id.fresh ())
           ~composition_run_id:(Masc.Keeper_tool_plan.Composition_run_id.fresh ())
           ~parent_invocation:
             (composition_invocation
                ~completion:Agent_core.Tool_contract.Continue_after_success)
           ~config
           ~meta
           ~publication_recovery
           ~ctx_snapshot:ctx_work
           ()
       with
       | Error _ -> fail "canonical exact-descriptor composition execution failed"
       | Ok [ result ] ->
         (match result.Masc.Keeper_tool_plan_executor.result with
          | Tool_result.Completed _ -> ()
          | Tool_result.Deferred _ | Tool_result.Failed _ ->
            fail "canonical time descriptor did not complete");
         check bool
           "canonical concurrent schedule"
           true
           (result.schedule.execution_mode = Agent_core.Tool_contract.Concurrent)
       | Ok _ -> fail "single-node composition settled an unexpected result count")
;;

let test_composition_terminal_requires_terminal_outer_invocation () =
  with_exec_fixture "composition-terminal-outer-contract"
    (fun ~config ~meta ~publication_recovery ~ctx_work ->
       let descriptor = composition_descriptor "keeper_surface_post" in
       let node =
         Masc.Keeper_tool_plan.node
           ~id:(composition_node_id "terminal")
           ~tool_name:"keeper_surface_post"
           ~input:(Masc.Keeper_tool_plan.Json_template.literal (`Assoc []))
           ()
       in
       let plan =
         match Masc.Keeper_tool_plan.create ~descriptors:[ descriptor ] [ node ] with
         | Ok plan -> plan
         | Error _ -> fail "terminal composition plan was rejected"
       in
       match
         Masc.Keeper_tool_plan_executor.Compatibility.execute_keeper
           ~plan
           ~run_id:(Masc.Keeper_tool_plan.Run_id.fresh ())
           ~composition_run_id:(Masc.Keeper_tool_plan.Composition_run_id.fresh ())
           ~parent_invocation:
             (composition_invocation
                ~completion:Agent_core.Tool_contract.Continue_after_success)
           ~config
           ~meta
           ~publication_recovery
           ~ctx_snapshot:ctx_work
           ()
       with
       | Error
           { settled = []
           ; cause =
               Masc.Keeper_tool_plan_executor.Outer_completion_mismatch
                 { expected =
                     Agent_core.Tool_contract.Terminal_after_success
                       Agent_core.Tool_contract.Effect_outcome_unknown
                 ; actual = Agent_core.Tool_contract.Continue_after_success
                 }
           ; effect_disposition = Tool_result.Proven_pre_effect
           } -> ()
       | Error _ | Ok _ ->
         fail "terminal composition accepted an ordinary outer invocation")
;;


(* ── Composable output contract (#30594) ──────────────────────────────────

   One place, and only one, checks a tool's output against the schema its own
   descriptor declares: the composition executor, on the [Tool_result.data] of
   a completed node (keeper_tool_plan_executor.ml). A direct tool call never
   meets that schema. So a producer that grows a field the schema does not
   name stays healthy everywhere a person would look, and breaks every
   composition that touches it.

   keeper_tasks_list sat in that state for six days. #29012 declared the
   schema on 08-18; #29103 added matching_count / returned_count / truncated
   to the producer on 08-19 and left the schema alone. The drift surfaced only
   when a composition finally used the tool and failed on its own output.

   The two tests below close it from both sides. The first derives the tool
   list from the registry, so declaring [with_composable_output] on a new tool
   fails here until it is probed. The second runs the real producer and
   validates the exact value the executor validates, through a plan built the
   way the executor builds one. *)

module Plan = Masc.Keeper_tool_plan

(* The masc_* tools route through the RFC-0182 3.1 workspace dispatch ref,
   which Mcp_server_eio_execute fills from its own module initializer. Nothing
   else in this executable names that module, so the linker drops it and those
   tools fail before emitting anything. Naming one value links it. *)
let _links_workspace_dispatch_registration =
  Masc.Mcp_server_eio_execute.resolve_bind_state

let composable_model_names () =
  KTD.all_descriptors ()
  |> List.concat_map (fun descriptor ->
    match descriptor.KTD.composable_output with
    | KTD.Opaque_output -> []
    | KTD.Json_output _ -> KTD.keeper_model_names descriptor)
  |> List.sort_uniq String.compare

(* Arguments a keeper would actually send, not the smallest shape that passes:
   the probe exists to observe what the producer emits, so it has to reach the
   producer. [prepare] returns the arguments so a tool that needs durable
   state first — an artifact to read — can create it. *)
type output_probe =
  { tool_name : string
  ; prepare :
      config:Masc.Workspace.config
      -> meta:Masc.Keeper_meta_contract.keeper_meta
      -> Yojson.Safe.t
  }

let probe tool_name args =
  { tool_name; prepare = (fun ~config:_ ~meta:_ -> args) }

let composable_output_probes =
  [ probe "Execute" (`Assoc [ "argv", `List [ `String "/bin/echo"; `String "probe" ] ])
  ; probe "keeper_time_now" (`Assoc [])
  ; { tool_name = "keeper_tasks_list"
    ; prepare =
        (fun ~config ~meta:_ ->
           (* A tool that reads durable state needs some, or it fails before
              it can emit the shape under test.

              Two rows and a limit of one, not one row and no limit: this
              producer emits [next_cursor] only when a page is cut short, so
              an unpaged fixture never reaches that field. One row passed
              here while production failed on every composition holding a
              tasks node -- #32488 added the cursor to the response without
              widening the declared schema, and this probe could not see it
              (masc #32953). A probe that only meets the shape its fixture
              happens to produce does not cover the shapes the producer can
              produce. *)
           List.iter
             (fun title ->
                ignore
                  (Workspace.add_task
                     config
                     ~created_by:"composable-output-probe"
                     ~title
                     ~priority:3
                     ~description:""))
             [ "composable output probe"; "composable output probe (second page)" ];
           `Assoc [ "limit", `Int 1 ])
    }
  ; probe "masc_board_stats" (`Assoc [])
  ; probe "masc_board_list" (`Assoc [])
  ; { tool_name = "masc_goal_list"
    ; prepare =
        (fun ~config ~meta:_ ->
           (* An empty list validates the envelope and nothing else. The goal
              item's own fields -- id, title, priority, phase, timestamps --
              live inside [goals], so a probe that leaves it empty never puts
              them in front of the schema. Same shape of blind spot that let
              the keeper_tasks_list cursor drift through (masc #33000). *)
           ignore
             (Goal_store.upsert_goal
                config
                ~title:"composable output probe goal"
                ~metric:"probes covered"
                ~target_value:"1"
                ~priority:2
                ());
           `Assoc [])
    }
  ; { tool_name = "masc_run_list"
    ; prepare =
        (fun ~config ~meta:_ ->
           (* Same reason as the goal probe: the run item's task_id, plan and
              timestamps are only reachable through a non-empty [runs]. *)
           let stamp = "2026-01-01T00:00:00Z" in
           Masc.Run_eio.write_run
             config
             { Masc.Run_eio.task_id = "composable-output-probe-run"
             ; agent_name = None
             ; plan = "probe plan"
             ; created_at = stamp
             ; updated_at = stamp
             };
           `Assoc [])
    }
  ; { tool_name = "masc_get_metrics"
    ; prepare =
        (fun ~config:_ ~meta -> `Assoc [ "agent_name", `String meta.Masc.Keeper_meta_contract.name ])
    }
  ; { tool_name = "masc_agent_fitness"
    ; prepare =
        (fun ~config:_ ~meta -> `Assoc [ "agent_name", `String meta.Masc.Keeper_meta_contract.name ])
    }
  ; { tool_name = "keeper_artifact_read"
    ; prepare =
        (fun ~config ~meta:_ ->
           let store = Tool_blob_store.create ~base_path:config.Masc.Workspace.base_path in
           let reference =
             Tool_blob_store.put_durable
               store
               ~bytes:"composable output probe"
               ~mime:"text/plain"
           in
           `Assoc [ "sha256", `String reference.Tool_output.sha256 ])
    }
  ]

let test_every_composable_tool_has_an_output_probe () =
  let declared = composable_model_names () in
  let probed =
    List.map (fun probe -> probe.tool_name) composable_output_probes
    |> List.sort_uniq String.compare
  in
  let only_in left right =
    List.filter (fun name -> not (List.mem name right)) left
  in
  (match only_in declared probed with
   | [] -> ()
   | missing ->
     failf
       "these tools declare a composable output and no probe runs their \
        producer against it: %s"
       (String.concat ", " missing));
  match only_in probed declared with
  | [] -> ()
  | stale ->
    failf
      "these probes name tools that no longer declare a composable output: %s"
      (String.concat ", " stale)

let schema_value_error_to_string = function
  | Plan.Unsupported_schema_type json ->
    "unsupported schema type " ^ Yojson.Safe.to_string json
  | Plan.Missing_required_field { path; field } ->
    Printf.sprintf "missing required field %S under /%s" field (String.concat "/" path)
  | Plan.Unexpected_field { path; field } ->
    Printf.sprintf "undeclared field %S under /%s" field (String.concat "/" path)
  | Plan.Duplicate_value_field { path; field } ->
    Printf.sprintf "duplicate field %S under /%s" field (String.concat "/" path)
  | Plan.Type_mismatch { path; _ } ->
    Printf.sprintf "type mismatch under /%s" (String.concat "/" path)

let validate_probe_output ~tool_name ~data =
  let node_id =
    match Plan.Node_id.make "probe" with
    | Ok id -> id
    | Error Plan.Node_id.Empty -> fail "probe node id was empty"
  in
  let node =
    Plan.node
      ~id:node_id
      ~tool_name
      ~input:(Plan.Json_template.literal (`Assoc []))
      ()
  in
  match Plan.create ~descriptors:(KTD.all_descriptors ()) [ node ] with
  | Error error ->
    failf
      "%s could not be a composition node at all: %s"
      tool_name
      (Plan.error_to_string error)
  | Ok plan ->
    (match
       Plan.validate_output plan ~run_id:(Plan.Run_id.fresh ()) ~node_id data
     with
     | Ok _ -> ()
     | Error (Plan.Output_validation_failed { error; _ }) ->
       failf
         "%s produced a value its own declared output schema rejects (%s): %s"
         tool_name
         (schema_value_error_to_string error)
         (Yojson.Safe.to_string data)
     | Error _ ->
       failf "%s output validation failed before reaching the schema" tool_name)

let test_composable_outputs_satisfy_declared_schema () =
  with_exec_fixture
    ~process:true
    ~always_allow:true
    ~bind_eio_context:true
    "keeper_tool_dispatch_runtime_composable_output"
    (fun ~config ~meta ~publication_recovery ~ctx_work ->
       (* Every probe reads durable workspace state. An uninitialized base
          path fails them before they reach the shape under test. *)
       ignore (Workspace.init config ~agent_name:None);
       ignore
         (Workspace.bind_session
            config
            ~agent_name:meta.Masc.Keeper_meta_contract.name
            ~capabilities:[]
            ());
       (* masc_get_metrics and masc_agent_fitness both read this store and
          reject with not_found when it is empty, before emitting any shape. *)
       let now = Unix.gettimeofday () in
       Masc.Metrics_store_eio.record
         config
         { Masc.Metrics_store_eio.id = Masc.Metrics_store_eio.generate_id ()
         ; agent_id = meta.Masc.Keeper_meta_contract.name
         ; task_id = "composable-output-probe"
         ; started_at = now
         ; completed_at = Some now
         ; success = true
         ; error_message = None
         ; collaborators = []
         ; handoff_from = None
         ; handoff_to = None
         };
       (* Every probe runs, then the failures are reported together.

          Aborting at the first one hides the rest: [Execute] leads this list
          and needs a sandbox runtime, so on a machine with no container
          daemon it failed first and the nine probes behind it never ran --
          the gate reported one problem while saying nothing about the tools
          it exists to cover. One unavailable runtime is not a reason to stop
          asking the other producers whether they still match their declared
          schema. *)
       let failures =
         List.filter_map
           (fun { tool_name; prepare } ->
              let input = prepare ~config ~meta in
              let result =
                KET.execute_keeper_tool_call_with_outcome
                  ~config
                  ~meta
                  ~publication_recovery
                  ~ctx_work
                  ~name:tool_name
                  ~input
                  ()
              in
              if not (String.equal "success" (outcome_label result.KTE.disposition))
              then
                Some
                  (Printf.sprintf
                     "%s did not complete, so its output went unobserved: %s"
                     tool_name
                     result.KTE.raw_output)
              else (
                match result.KTE.data with
                | Some data ->
                  (* Alcotest's [fail] raises its own exception, not
                     [Failure], so catching [Failure] alone let a schema
                     rejection escape and abort the loop again -- the very
                     thing this collector exists to stop. Catch every
                     exception a probe can raise and keep its message. *)
                  (try
                     validate_probe_output ~tool_name ~data;
                     None
                   with
                   | Failure detail -> Some detail
                   | exn -> Some (Printexc.to_string exn))
                | None ->
                  Some
                    (Printf.sprintf
                       "%s completed without typed data; a composition node \
                        would have nothing to validate"
                       tool_name)))
           composable_output_probes
       in
       match failures with
       | [] -> ()
       | failures ->
         failf
           "%d of %d composable-output probes failed:\n%s"
           (List.length failures)
           (List.length composable_output_probes)
           (String.concat "\n" failures))

let () =
  Masc_test_deps.init_unified_tool_registry ();
  run "Keeper_tool_dispatch_runtime" [
    ("execute_keeper_tool_call_with_outcome", [
      test_case "public Read rejects unsupported range fields" `Quick
        test_public_read_rejects_unsupported_range_fields;
      test_case "public Read rejects offset without dispatch enrichment" `Quick
        test_public_read_accepts_offset_without_enrichment;
      test_case "surface Read rejects duplicate dispatch fields" `Quick
        test_surface_read_rejects_duplicate_dispatch_fields;
      test_case "missing file is failure" `Quick
        test_execute_with_outcome_missing_file_is_failure;
      test_case "initializing recovery isolates only publication writes" `Quick
        test_initializing_recovery_isolates_only_publication_writes;
      test_case "identical Keeper invocations join across production boundaries" `Quick
        test_identical_keeper_invocations_join_across_production_boundaries;
      test_case "Manual Gate does not defer internal memory write" `Quick
        test_manual_gate_does_not_defer_internal_memory_write;
      test_case "initialization crash is redacted from tool output" `Quick
        test_publication_initialization_crash_is_redacted;
      test_case "reconciliation evidence is redacted from tool output" `Quick
        test_publication_reconciliation_evidence_is_redacted;
      test_case "registry evidence is redacted from tool output" `Quick
        test_publication_registry_evidence_is_redacted;
      test_case "publication Write rereads provider after initialization" `Quick
        test_publication_write_rereads_live_provider_after_initialization;
      test_case "publication Write cancellation releases exact lane" `Quick
        test_publication_write_cancellation_releases_exact_lane;
      test_case "committed publication preserves cleanup failure truth" `Quick
        test_real_publication_release_failure_preserves_effect_truth;
      test_case "directory publication preserves cleanup failure truth" `Quick
        test_real_directory_release_failure_preserves_effect_truth;
      test_case "model-visible local tools dispatch to runtime handlers" `Quick
        test_model_visible_local_tools_dispatch_to_runtime_handlers;
      test_case "keeper_task_claim accepts explicit task_id" `Quick
        test_keeper_task_claim_accepts_specific_task_id;
      test_case "unknown tool returns exact error" `Quick
        test_unknown_tool_returns_exact_error;
      test_case "model-visible WebSearch reaches misc runtime" `Quick
        test_model_visible_web_search_dispatches_to_misc_runtime;
      test_case "model-visible WebFetch reaches misc runtime" `Quick
        test_model_visible_web_fetch_dispatches_to_misc_runtime;
      test_case "model-visible masc_ask records the question" `Quick
        test_model_visible_masc_ask_records_the_question;
      test_case "public WebFetch rejects localhost after Gate" `Quick
        test_public_masc_web_fetch_rejects_localhost_after_gate;
      test_case "Manual Gate defers web tools before network" `Quick
        test_manual_gate_defers_web_tools_before_network;
      test_case "approved WebSearch grant executes exact request" `Quick
        test_approved_web_search_grant_executes_exact_request;
      test_case "approved WebSearch replays without model resubmission" `Quick
        test_approved_web_search_replays_without_model_resubmission;
      test_case "durable connector replay settles terminal turn" `Quick
        test_durable_connector_replay_settles_terminal_turn;
      test_case "blob failure repairs journal without second effect" `Quick
        test_blob_failure_repairs_journal_without_second_effect;
      test_case "journal failure retries only persistence" `Quick
        test_journal_failure_retries_only_persistence;
      test_case "unknown effect is durable and not replayed" `Quick
        test_unknown_effect_is_durable_and_not_replayed;
      test_case "consumed outcome gap settles indeterminate" `Quick
        test_consumed_without_outcome_is_terminal_indeterminate;
      test_case "unsupported approval retains exact model-issued path" `Quick
        test_unsupported_approved_operation_retains_exact_model_issued_path;
      test_case "task FSM errors require explicit failure_class" `Quick
        test_tool_result_does_not_infer_task_fsm_rejections_from_message;
      test_case "Manual Gate defers tool_execute before process" `Quick
        test_manual_gate_defers_tool_execute_before_process;
      test_case "tool_execute raw cmd requires typed Shell IR" `Quick
        test_tool_execute_raw_cmd_requires_typed_shell_ir;
      test_case "tool_execute script form is admitted and runs" `Quick
        test_tool_execute_script_form_is_admitted_and_runs;
      test_case "tool_execute empty input names all three forms" `Quick
        test_tool_execute_empty_input_names_all_three_forms;
      test_case "Agent Core handler threads Eio context to keeper dispatch" `Quick
        test_agent_core_handler_threads_eio_context_to_keeper_dispatch;
      test_case "registered dispatch does not require masc_ prefix" `Quick
        test_registered_tool_dispatch_without_masc_prefix;
      test_case "registered dispatch preserves workflow failure class" `Quick
        test_registered_dispatch_preserves_workflow_failure_class;
      test_case "success payload containing error data stays success" `Quick
        test_success_payload_with_error_data_stays_success;
      test_case "malformed JSON-looking success stays success" `Quick
        test_malformed_json_looking_success_stays_success;
      test_case "only typed producer failure is failure" `Quick
        test_only_typed_producer_failure_is_failure;
      test_case "deferred WebSearch keeps the turn going" `Quick
        test_deferred_web_search_keeps_the_turn_going;
      test_case "invalid surface input stays correction-capable" `Quick
        test_invalid_surface_post_input_stays_correction_capable;
      test_case "surface append failure is not terminal completion" `Quick
        test_surface_post_append_failure_does_not_complete_terminal_effect;
      test_case "frozen surface rejects a registered-only tool" `Quick
        test_frozen_surface_direct_dispatch_rejects_registered_only_tool;
      test_case "frozen surface accepts its exact descriptor" `Quick
        test_frozen_surface_direct_dispatch_accepts_included_exact_descriptor;
      test_case "frozen surface rejects a same-id counterfeit descriptor" `Quick
        test_frozen_surface_rejects_same_id_counterfeit_descriptor;
      test_case "production frozen bundle executes public Read" `Quick
        test_frozen_surface_production_bundle_executes_public_read;
      test_case "frozen surface rejects a non-exposed descriptor alias" `Quick
        test_frozen_surface_name_dispatch_rejects_non_exposed_alias;
      test_case "composition dispatch uses canonical descriptor authority" `Quick
        test_composition_runtime_uses_canonical_descriptor;
      test_case "catalog composition is a first-class executable tool" `Quick
        test_composition_catalog_materializes_and_executes_first_class_tool;
      test_case "compositions share the closed turn descriptor set" `Quick
        test_compositions_share_closed_turn_descriptor_set;
      test_case "composition feeds typed Shell IR output to later tool" `Quick
        test_composition_feeds_typed_shell_ir_output_to_later_tool;
      test_case "composition externalizes oversized Shell IR output" `Quick
        test_composition_externalizes_oversized_shell_ir_output;
      test_case "direct Execute artifact manifest survives maintenance" `Quick
        test_direct_execute_artifact_manifest_survives_maintenance;
      test_case "direct Execute artifact failure closes official-client loop" `Quick
        test_direct_execute_post_effect_artifact_failure_closes_official_client_loop;
      test_case "direct pre-effect and read-only failures remain correction-capable" `Quick
        test_direct_pre_effect_and_readonly_failures_remain_correction_capable;
      test_case "stale spawn handles remain correction-capable" `Quick
        test_stale_spawn_handles_remain_correction_capable;
      test_case "composition action commit refreshes dashboard evidence" `Quick
        test_composition_action_commit_advances_revision_before_refresh_event;
      test_case "composition telemetry outage preserves execution" `Quick
        test_composition_telemetry_failure_does_not_change_execution;
      test_case "terminal catalog composition keeps terminal completion" `Quick
        test_terminal_composition_materializes_terminal_completion;
      test_case "composition failure exposes typed plan cause" `Quick
        test_composition_plan_failure_exposes_typed_cause;
      test_case "post-effect composition closes official-client loop" `Quick
        test_terminal_composition_post_effect_failure_closes_official_client_loop;
      test_case "unknown-effect composition closes official-client loop" `Quick
        test_terminal_composition_unknown_write_failure_closes_official_client_loop;
      test_case "post-effect deferred composition closes without resume" `Quick
        test_terminal_composition_post_effect_defer_closes_without_resume;
      test_case "async composition binds params into durable status" `Quick
        test_async_composition_binds_params_into_durable_status;
      test_case "async composition status preserves artifact manifest" `Quick
        test_async_composition_status_preserves_artifact_manifest;
      test_case "terminal composition requires terminal outer invocation" `Quick
        test_composition_terminal_requires_terminal_outer_invocation;
    ]);
    ("exact_registered_dispatch", [
      test_case "raw Board runtime respects typed projection" `Quick
        test_board_runtime_rejects_unknown_route;
    ]);
    ("keeper_tools_list_json", [
      test_case "names the model visible tools" `Quick
        test_keeper_tools_list_json_names_the_model_visible_tools;
      test_case "lists and searches operator-only Tools" `Quick
        test_frozen_surface_lists_and_searches_operator_only_tool;
      test_case "Agent Core receives typed search failures" `Quick
        test_tools_search_error_reaches_agent_core_as_typed_payload;
      test_case "descriptor route miss is typed runtime failure" `Quick
        test_descriptor_route_miss_payload_is_typed_runtime_failure;
    ]);
    ("composable_output_contract", [
      test_case "every composable tool has an output probe" `Quick
        test_every_composable_tool_has_an_output_probe;
      test_case "real producer output satisfies its declared schema" `Quick
        test_composable_outputs_satisfy_declared_schema;
    ]);
    ("agent_core_descriptor", [
      test_case "catalog flags do not infer Agent Core descriptors" `Quick
        test_catalog_metadata_does_not_infer_agent_core_descriptors;
      test_case "model-visible tools keep canonical Agent Core descriptors" `Quick
        test_model_visible_tools_keep_canonical_agent_core_descriptors;
      test_case "surface post description reaches the Agent Core bundle" `Quick
        test_surface_post_bundle_names_reader_and_repeat_cost;
    ]);
  ]
