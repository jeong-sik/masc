open Alcotest

module KET = Masc.Keeper_tool_dispatch_runtime
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

let make_meta ?(name = "keeper-exec-tools") () =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [
          ("name", `String name);
          ("agent_name", `String name);
          ("trace_id", `String "keeper-exec-tools-trace");
          ("allowed_paths", `List [ `String "*" ]);
        ])
  with
  | Ok meta -> meta
  | Error err -> failwith ("make_meta failed: " ^ err)

let make_ctx () =
  Masc.Keeper_context_runtime.create ~eio:false ~system_prompt:"test"
    ~max_tokens:4000

let with_exec_fixture ?(process = false) ?(always_allow = false) name fn =
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
      let meta =
        let meta = { (make_meta ()) with allowed_paths = [ config.base_path ] } in
        if always_allow then { meta with always_allow = Some true } else meta
      in
      ignore (Masc.Keeper_registry.register ~base_path:config.base_path meta.name meta);
      Fun.protect
        ~finally:(fun () ->
          Masc.Keeper_registry.unregister ~base_path:config.base_path meta.name)
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
               fn
                 ~config
                 ~meta
                 ~publication_recovery
                 ~ctx_work:(make_ctx ()))))

let contains_substring text needle =
  let text_len = String.length text in
  let needle_len = String.length needle in
  let rec loop idx =
    idx + needle_len <= text_len
    && (String.sub text idx needle_len = needle || loop (idx + 1))
  in
  needle_len = 0 || loop 0

let parse_json raw =
  try Yojson.Safe.from_string raw with
  | Yojson.Json_error err -> fail ("invalid json: " ^ err)

let outcome_label = function
  | `Success -> "success"
  | `Failure _ -> "failure"

let tool_call_detail_of_execution tool_name
      (result : KET.executed_tool_result)
  : Masc.Keeper_agent_result.tool_call_detail
  =
  let execution_outcome =
    match result.outcome with
    | `Success -> Tool_result.Ok
    | `Failure _ -> Tool_result.Error
  in
  { tool_name
  ; provider = "test"
  ; outcome = Tool_result.string_of_tool_call_outcome execution_outcome
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
  if not (String.equal "success" (outcome_label result.KET.outcome))
  then
    fail
      (Printf.sprintf
         "%s expected success, got %s: %s"
         label
         (outcome_label result.KET.outcome)
         result.KET.raw_output);
  let json = Yojson.Safe.from_string result.KET.raw_output in
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
          ~exec_cache:None
          ~name:"Read"
          ~input:
            (`Assoc
               [ "file_path", `String "lib/keeper/keeper_transition_audit.ml"
               ; "start_line", `Int 255
               ])
          ()
      in
      check string "runtime outcome" "failure"
        (match result.outcome with `Success -> "success" | `Failure _ -> "failure");
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
        (contains_substring error "unsupported field");
      check bool "error mentions start_line" true
        (contains_substring error "start_line");
      check string "validation source" "oas_tool_middleware"
        Yojson.Safe.Util.(member "validation" json |> to_string);
      check string "failure class" "policy_rejection"
        Yojson.Safe.Util.(member "failure_class" json |> to_string);
      check bool "dispatch does not add a tutor" true
        Yojson.Safe.Util.(member "tool_tutor" json = `Null);
      check bool "did not reach file runtime" false
        (match Yojson.Safe.Util.member "path_resolution" json with
         | `Assoc _ -> true
         | _ -> false))

let test_public_read_rejects_offset_without_enrichment () =
  with_exec_fixture
    "keeper_tool_dispatch_runtime_read_rejects_offset"
    (fun ~config ~meta ~publication_recovery ~ctx_work ->
      let result =
        KET.execute_keeper_tool_call_with_outcome
          ~config
          ~meta
          ~publication_recovery
          ~ctx_work
          ~exec_cache:None
          ~name:"Read"
          ~input:
            (`Assoc
               [ "file_path", `String "lib/keeper/keeper_transition_audit.ml"
               ; "offset", `Int 100
               ])
          ()
      in
      check string "runtime outcome" "failure" (outcome_label result.outcome);
      let json =
        match result.data with
        | Some data -> data
        | None -> fail "validation rejection omitted typed data"
      in
      check bool "dispatch does not add a tutor" true
        Yojson.Safe.Util.(member "tool_tutor" json = `Null);
      check bool "validation names exact field" true
        (contains_substring result.raw_output "offset"))

let test_raw_board_runtime_respects_projection () =
  let meta = make_meta ~name:"keeper-board-runtime-guard" () in
  let check_rejection board_name expected_kind expected_class =
    let name = Tool_name.Board_name.to_string board_name in
    let raw =
      Masc.Keeper_tool_in_process_runtime.handle_masc_board
        ~meta
        ~name
        ~args:(`Assoc [])
    in
    let json = Yojson.Safe.from_string raw in
    check string
      (name ^ " rejection kind")
      expected_kind
      Yojson.Safe.Util.(member "error_kind" json |> to_string);
    check string
      (name ^ " failure class")
      expected_class
      Yojson.Safe.Util.(member "failure_class" json |> to_string);
  in
  check_rejection
    Tool_name.Board_name.Board_post
    "keeper_wrapper_required"
    "policy_rejection";
  let raw =
    Masc.Keeper_tool_in_process_runtime.handle_masc_board
      ~meta
      ~name:"masc_board_not_registered"
      ~args:(`Assoc [])
  in
  let json = Yojson.Safe.from_string raw in
  check string
    "unknown Board route is explicit"
    "unknown_board_route"
    Yojson.Safe.Util.(member "error_kind" json |> to_string);
  check string
    "unknown Board route is a runtime invariant failure"
    "runtime_failure"
    Yojson.Safe.Util.(member "failure_class" json |> to_string)
;;

let test_keeper_tools_list_json_uses_typed_groups () =
  let meta = make_meta () in
  let json = Yojson.Safe.from_string (KES.keeper_tools_list_json ~meta) in
  let member group name =
    json_list_contains name Yojson.Safe.Util.(member group json)
  in
  check bool "board canonical tool grouped" true
    (member "board" "keeper_board_post");
  check bool "fake board-looking tool excluded" false
    (json_contains_tool "keeper_board_fake" json);
  check bool "voice tool grouped" true
    (member "voice" "keeper_voice_speak");
  check bool "task tool grouped as workspace" true
    (member "workspace" "keeper_task_claim");
  check bool "MASC task tool grouped as workspace" true
    (member "workspace" "masc_transition");
  check bool "MASC plan tool grouped as workspace" true
    (member "workspace" "masc_plan_get");
  check bool "surface read grouped as surface" true
    (member "surface" "keeper_surface_read");
  check bool "surface read not hidden under meta" false
    (member "meta" "keeper_surface_read");
  check bool "tools_list remains a meta introspection tool" true
    (member "meta" "keeper_tools_list");
  check bool "Grep tool grouped under its sole model name" true
    (member "search_files" "Grep");
  check bool "Grep internal route omitted from model list" false
    (member "search_files" "tool_search_files");
  check bool "fs tool grouped under its sole model name" true
    (member "fs" "Read");
  check bool "memory tool grouped" true
    (member "memory" "keeper_memory_search");
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
  check string "discovery_json wraps discovery_fields"
    (Yojson.Safe.to_string (`Assoc execute_fields))
    (Yojson.Safe.to_string (KTD.discovery_json execute_descriptor));
  let execute = find_descriptor "tool_execute" in
  check string "Execute public alias" "Execute"
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
  check bool "Execute schema properties include pipeline" true
    (list_member_contains "properties" "pipeline" schema_shape);
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
  check bool "Grep compatibility alias is not a model name" false
    (list_member_contains "active_names" "Search" grep);
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
      KTD.discovery_json malformed_execute |> member "schema_shape")
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
          [ "properties", `Assoc [ "argv", `Assoc []; "pipeline", `Assoc [] ]
          ; "oneOf"
          , `List
              [ `Assoc [ "required", `List [ `String "argv" ] ]
              ; `Assoc [ "required", `List [] ]
              ]
          ]
    }
  in
  let one_of_shape =
    Yojson.Safe.Util.(KTD.discovery_json one_of_execute |> member "schema_shape")
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
      KTD.discovery_json
        { (descriptor_for_internal "tool_execute") with
          KTD.input_schema = `Assoc []
        }
      |> member "schema_shape")
  in
  check int "empty schema has no properties" 0
    Yojson.Safe.Util.(member "properties" empty_shape |> to_list |> List.length);
  check int "empty schema has no required names" 0
    Yojson.Safe.Util.(member "required" empty_shape |> to_list |> List.length);
  check bool "empty schema has no shape errors" true
    (Yojson.Safe.Util.member "schema_errors" empty_shape = `Null);
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
          ~config ~meta ~publication_recovery ~ctx_work ~exec_cache:None
          ~name:"Read"
          ~input:(`Assoc [ ("file_path", `String "config/runtime.toml") ])
          ()
      in
      check string "missing file outcome" "failure"
        (match result.outcome with `Success -> "success" | `Failure _ -> "failure");
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
  check string (label ^ " outcome") "failure" (outcome_label result.KET.outcome);
  (match result.outcome with
   | `Failure Tool_result.Runtime_failure -> ()
   | `Failure failure_class ->
     failf
       "%s wrong failure class: %s"
       label
       (Tool_result.tool_failure_class_to_string failure_class)
   | `Success -> fail (label ^ " unexpectedly succeeded"));
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
  check string (label ^ " outcome") "failure" (outcome_label result.KET.outcome);
  (match result.outcome with
   | `Failure Tool_result.Runtime_failure -> ()
   | `Failure failure_class ->
     failf
       "%s returned wrong failure class: %s"
       label
       (Tool_result.tool_failure_class_to_string failure_class)
   | `Success -> fail (label ^ " unexpectedly wrote a file"));
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
         (contains_substring public_output sentinel))
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
       let existing_path = Filename.concat config.base_path "existing.txt" in
       let untouched = "original bytes" in
       write_file existing_path untouched;
       let execute ~name ~input =
         KET.execute_keeper_tool_call_with_outcome
           ~config
           ~meta
           ~publication_recovery
           ~ctx_work
           ~exec_cache:None
           ~name
           ~input
           ()
       in
       let time_result = execute ~name:"keeper_time_now" ~input:(`Assoc []) in
       check string
         "non-file tool continues"
         "success"
         (outcome_label time_result.outcome);
       let read_result =
         execute
           ~name:"Read"
           ~input:(`Assoc [ "file_path", `String existing_path ])
       in
       check string
         "read continues"
         "success"
         (outcome_label read_result.outcome);
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
         (outcome_label append_existing.outcome);
       check string
         "append publishes exact bytes while recovery initializes"
         (untouched ^ " + appended")
         (read_file existing_path);
       let append_created_path =
         Filename.concat config.base_path "append-created.txt"
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
         (outcome_label append_created.outcome);
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
         (outcome_label invalid_write.outcome);
       check int "invalid Write performs no recovery acquisition" 0
         (Atomic.get provider_reads);
       let write_path = Filename.concat config.base_path "must-not-exist.txt" in
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

let test_manual_gate_defers_publication_writes_before_recovery () =
  with_exec_fixture
    "keeper_tool_dispatch_manual_publication_gate"
    (fun ~config ~meta ~publication_recovery:_ ~ctx_work ->
       (match
          Masc.Keeper_gate_mode.set
            config
            ~actor:"test"
            Masc.Keeper_gate_mode.Manual
        with
        | Ok _ -> ()
        | Error detail -> fail ("failed to select Manual Gate mode: " ^ detail));
       let provider_reads = Atomic.make 0 in
       let publication_recovery =
         { Publication_availability.provider =
             (fun () ->
                Atomic.incr provider_reads;
                Publication_availability.Initializing)
         ; keeper_name = meta.name
         }
       in
       let path = Filename.concat config.base_path "manual-gate.txt" in
       let original = "manual gate original" in
       write_file path original;
       let execute ~name ~input =
         KET.execute_keeper_tool_call_with_outcome
           ~config
           ~meta
           ~publication_recovery
           ~ctx_work
           ~exec_cache:None
           ~name
           ~input
           ()
       in
       let overwrite =
         execute
           ~name:"Write"
           ~input:
             (`Assoc
                [ "file_path", `String path
                ; "content", `String "must not overwrite"
                ])
       in
       let edit =
         execute
           ~name:"Edit"
           ~input:
             (`Assoc
                [ "file_path", `String path
                ; "old_string", `String original
                ; "new_string", `String "must not edit"
                ])
       in
       List.iter
         (fun result ->
            check string "Manual Gate outcome" "failure"
              (outcome_label result.KET.outcome);
            check string
              "Manual Gate returns typed defer"
              "gate_deferred"
              Yojson.Safe.Util.
                (member "error" (parse_json result.raw_output) |> to_string))
         [ overwrite; edit ];
       check int
         "Manual Gate defers publication writes before provider acquisition"
         0
         (Atomic.get provider_reads);
       check string "Manual Gate preserves exact target bytes" original
         (read_file path))
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
       let path = Filename.concat config.base_path "crash-must-not-write.txt" in
       let result =
         KET.execute_keeper_tool_call_with_outcome
           ~config
           ~meta
           ~publication_recovery
           ~ctx_work
           ~exec_cache:None
           ~name:"Write"
           ~input:
             (`Assoc
                [ "file_path", `String path
                ; "content", `String "must not be published"
                ])
           ()
       in
       (match result.outcome with
        | `Failure Tool_result.Runtime_failure -> ()
        | `Failure failure_class ->
          failf
            "crashed initialization returned wrong failure class: %s"
            (Tool_result.tool_failure_class_to_string failure_class)
        | `Success -> fail "crashed initialization unexpectedly wrote a file");
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
         (contains_substring result.raw_output exception_text);
       check bool
         "exception payload is absent from data"
         false
         (contains_substring rendered_data exception_text);
       if backtrace_text <> ""
       then (
         check bool
           "backtrace is absent from message"
           false
           (contains_substring result.raw_output backtrace_text);
         check bool
           "backtrace is absent from data"
           false
           (contains_substring rendered_data backtrace_text));
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
       let target = Filename.concat config.base_path "must-not-write.txt" in
       let result =
         KET.execute_keeper_tool_call_with_outcome
           ~config
           ~meta
           ~publication_recovery
           ~ctx_work
           ~exec_cache:None
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
       let target = Filename.concat config.base_path "registry-must-not-write.txt" in
       let result =
         KET.execute_keeper_tool_call_with_outcome
           ~config
           ~meta
           ~publication_recovery
           ~ctx_work
           ~exec_cache:None
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
       let path = Filename.concat config.base_path "after-initialization.txt" in
       let execute () =
         KET.execute_keeper_tool_call_with_outcome
           ~config
           ~meta
           ~publication_recovery
           ~ctx_work
           ~exec_cache:None
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
         (outcome_label available.outcome);
       check string "next Write published exact bytes" "available" (read_file path);
       check int "provider was reread once for each Write" 2
         (Atomic.get provider_reads);
       let edit =
         KET.execute_keeper_tool_call_with_outcome
           ~config
           ~meta
           ~publication_recovery
           ~ctx_work
           ~exec_cache:None
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
         (outcome_label edit.outcome);
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
       let target = Filename.concat config.base_path "release-effect.txt" in
       let execute_at target content =
         KET.execute_keeper_tool_call_with_outcome
           ~config
           ~meta
           ~publication_recovery
           ~ctx_work
           ~exec_cache:None
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
         (outcome_label warmup.outcome);
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
       (match committed.outcome with
        | `Failure Tool_result.Runtime_failure -> ()
        | `Failure failure_class ->
          failf
            "cleanup failure received wrong class: %s"
            (Tool_result.tool_failure_class_to_string failure_class)
        | `Success -> fail "cleanup failure was reported as success");
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
         (outcome_label recovered.outcome);
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
       (match failed_after_replace.outcome with
        | `Failure Tool_result.Runtime_failure -> ()
        | `Failure failure_class ->
          failf
            "post-replace cleanup failure received wrong class: %s"
            (Tool_result.tool_failure_class_to_string failure_class)
        | `Success -> fail "post-replace cleanup failure was reported as success");
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
         (outcome_label recovered_after_callback_failure.outcome);
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
         (outcome_label recovered_after_unknown.outcome);
       let created_parent =
         Filename.concat config.base_path "created-parent-effect"
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
           ~exec_cache:None
           ~name:"Write"
           ~input:
             (`Assoc
                [ "file_path", `String target
                ; "content", `String content
                ])
           ()
       in
       let warmup_target = Filename.concat config.base_path "lane-warmup.txt" in
       let warmup = execute warmup_target "warmup" in
       check string "directory matrix warmup succeeds" "success"
         (outcome_label warmup.outcome);
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
         let parent = Filename.concat config.base_path label in
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
         (match result.outcome with
          | `Failure Tool_result.Runtime_failure -> ()
          | `Failure failure_class ->
            failf
              "%s returned wrong failure class: %s"
              label
              (Tool_result.tool_failure_class_to_string failure_class)
          | `Success -> failf "%s unexpectedly succeeded" label);
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
           (outcome_label result.outcome)
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

let test_tool_search_without_session_searcher_is_unavailable () =
  with_exec_fixture "keeper_tool_dispatch_runtime_search_unavailable"
    (fun ~config ~meta ~publication_recovery ~ctx_work ->
      let result =
        KET.execute_keeper_tool_call_with_outcome
          ~config ~meta ~publication_recovery ~ctx_work ~exec_cache:None
          ~name:"keeper_tool_search"
          ~input:(`Assoc [])
          ()
      in
      check string "search outcome" "failure" (outcome_label result.outcome);
      let json = Yojson.Safe.from_string result.raw_output in
      check string "explicit unavailable error" "tool_search_unavailable"
        Yojson.Safe.Util.(member "error" json |> to_string);
      check string "exact unavailable reason" "catalog_provider_not_injected"
        Yojson.Safe.Util.(member "reason" json |> to_string);
      check bool "no guessed results" true
        Yojson.Safe.Util.(member "results" json = `Null))

let test_tool_search_uses_exact_injected_searcher () =
  with_exec_fixture "keeper_tool_dispatch_runtime_injected_search"
    (fun ~config ~meta ~publication_recovery ~ctx_work ->
      let observed = ref false in
      let search_fn () =
        observed := true;
        Masc.Keeper_tool_execution.success
          (Yojson.Safe.to_string
             (`Assoc
               [ "ok", `Bool true
               ; "results", `List [ `Assoc [ "name", `String "injected-result" ] ]
               ]))
      in
      let result =
        KET.execute_keeper_tool_call_with_outcome
          ~config ~meta ~publication_recovery ~ctx_work ~exec_cache:None ~search_fn
          ~name:"keeper_tool_search"
          ~input:(`Assoc [])
          ()
      in
      check string "search outcome" "success" (outcome_label result.outcome);
      check bool "injected catalog provider called" true !observed;
      let json = Yojson.Safe.from_string result.raw_output in
      check string "injected result preserved" "injected-result"
        Yojson.Safe.Util.(member "results" json |> to_list |> List.hd
                          |> member "name" |> to_string))

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
          ~exec_cache:None
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
        (contains_substring grep_result.raw_output visible_file_path);
      check bool "Grep match includes content" true
        (contains_substring grep_result.raw_output "gamma");
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
      check bool "Execute ran in requested cwd" true
        (contains_substring execute_result.raw_output playground))

let test_keeper_task_claim_accepts_specific_task_id () =
  with_exec_fixture "keeper_tool_dispatch_specific_task_claim"
    (fun ~config ~meta ~publication_recovery ~ctx_work ->
      ignore (Workspace.init config ~agent_name:(Some meta.agent_name));
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
          ~exec_cache:None
          ~name:"keeper_task_claim"
          ~input:(`Assoc [ "task_id", `String "task-002" ])
          ()
      in
      check string "specific claim outcome" "success" (outcome_label result.outcome);
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
        check string "assignee" meta.agent_name assignee
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
          ~exec_cache:None
          ~name:"Glob"
          ~input:(`Assoc [ "pattern", `String "*.ml" ])
          ()
      in
      check string "runtime outcome" "failure" (outcome_label result.outcome);
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
            ( "duckduckgo",
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
              ~exec_cache:None
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
            (outcome_label result.outcome);
          let json = parse_json result.raw_output in
          let result_json = Yojson.Safe.Util.member "result" json in
          check string "status" "ok"
            Yojson.Safe.Util.(member "status" json |> to_string);
          check string "query preserved" "ocaml eio runtime test"
            Yojson.Safe.Util.(member "query" result_json |> to_string);
          check string "fallback provider selected" "duckduckgo"
            Yojson.Safe.Util.(member "engine" result_json |> to_string);
          check string "simulated provider url" "test://duckduckgo"
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
                 && contains_substring value "MASC-FetchWeb")
               headers);
          Ok (Some 200, html))
        (fun () ->
          let result =
            KET.execute_keeper_tool_call_with_outcome
              ~config
              ~meta
              ~publication_recovery
              ~ctx_work
              ~exec_cache:None
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
            (outcome_label result.outcome);
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
            (contains_substring
               Yojson.Safe.Util.(member "text" json |> to_string)
               "# Alias Fetch");
          check bool "body text cleaned" true
            (contains_substring
               Yojson.Safe.Util.(member "text" json |> to_string)
               "Body content & proof.")))

let test_public_masc_web_fetch_reaches_localhost_after_gate () =
  with_exec_fixture
    ~always_allow:true
    "keeper_tool_dispatch_web_fetch_reaches_localhost"
    (fun ~config ~meta ~publication_recovery ~ctx_work ->
      Masc.Tool_misc.with_web_fetch_http_get_for_test
        (fun ~timeout_sec:_ ~headers:_ ~max_response_bytes:_ url ->
          check string "local url forwarded" "http://127.0.0.1:8935/health" url;
          Ok (Some 200, "healthy"))
        (fun () ->
          let result =
            KET.execute_keeper_tool_call_with_outcome
              ~config
              ~meta
              ~publication_recovery
              ~ctx_work
              ~exec_cache:None
              ~name:"WebFetch"
              ~input:(`Assoc [ ("url", `String "http://127.0.0.1:8935/health") ])
              ()
          in
          check string "web fetch local outcome" "success"
            (outcome_label result.outcome);
          ()))

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
          [ ( "duckduckgo"
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
                  ~exec_cache:None
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
                  ~exec_cache:None
                  ~name:"WebFetch"
                  ~input:(`Assoc [ "url", `String "http://127.0.0.1:8935/health" ])
                  ()
              in
              List.iter
                (fun result ->
                   check string "Manual Gate outcome" "failure"
                     (outcome_label result.KET.outcome);
                   check string
                     "Manual Gate returns typed defer"
                     "gate_deferred"
                     Yojson.Safe.Util.
                       (member "error" (parse_json result.raw_output) |> to_string))
                [ search; fetch ];
              check int "Manual Gate executes no WebFetch callback" 0 !fetch_calls)))

let workflow_rejection_message =
  "Invalid task state: Self-approval not allowed: verifier must be a different agent"

let test_tool_result_does_not_infer_task_fsm_rejections_from_message () =
  let result =
    Tool_result.error
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

let test_tool_result_or_error_preserves_failure_class () =
  let result =
    Tool_result.error
      ~failure_class:(Some Tool_result.Workflow_rejection)
      ~tool_name:"masc_transition"
      ~start_time:(Unix.gettimeofday ())
      workflow_rejection_message
  in
  let json = Yojson.Safe.from_string (KES.tool_result_or_error result) in
  check string "failure_class" "workflow_rejection"
    Yojson.Safe.Util.(member "failure_class" json |> to_string)

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
        KET.execute_keeper_tool_call
          ~config ~meta ~publication_recovery ~ctx_work ~exec_cache:None
          ~name:"tool_execute" ~input ()
      in
      let outputs = List.init 4 (fun _ -> run ()) in
      List.iter
        (fun raw ->
           let json = Yojson.Safe.from_string raw in
           check string "typed shell ir required"
             "Typed Shell IR input is required. Provide non-empty argv or pipeline."
             Yojson.Safe.Util.(member "error" json |> to_string);
           check bool "typed marker" true
             Yojson.Safe.Util.(member "typed" json |> to_bool))
        outputs;
      match outputs with
      | first :: rest ->
        List.iter (check string "repeated failures stay byte-identical" first) rest
      | [] -> fail "expected dispatch outputs")

let keeper_msg_input_schema () =
  match
    List.find_opt
      (fun (schema : Masc_domain.tool_schema) ->
        String.equal schema.name "masc_keeper_msg")
      Masc.Keeper_schema.schemas
  with
  | Some schema -> schema.input_schema
  | None -> fail "masc_keeper_msg schema missing"

let test_oas_handler_threads_eio_context_to_keeper_dispatch () =
  let dir = temp_dir "oas-handler-eio-context" in
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
      ignore (Masc.Keeper_registry.register ~base_path:config.base_path meta.name meta);
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
      Fun.protect
        ~finally:(fun () ->
          Masc.Keeper_dispatch_ref.dispatch := previous_dispatch;
          Masc.Keeper_registry.unregister ~base_path:config.base_path meta.name)
        (fun () ->
          Masc.Keeper_dispatch_ref.dispatch :=
            (fun ~config:_ ~agent_name:_
                 ~publication_recovery_provider:observed_provider
                 ?sw ?clock ?proc_mgr:_ ?net:_ ?mcp_session_id:_
                 ?authorize_external_effect:_
                 ~name ~args:_ () ->
              check string "keeper dispatch tool" "masc_keeper_msg" name;
              Atomic.set saw_turn_sw
                (match sw with Some sw -> sw == turn_sw | None -> false);
              Atomic.set saw_clock (Option.is_some clock);
              Atomic.set saw_provider
                (observed_provider == publication_recovery.provider);
              Some
                (Tool_result.ok ~tool_name:name ~start_time:0.0
                   "{\"ok\":true,\"request_id\":\"test-request\"}"));
          let handler =
            Masc.Keeper_tools_oas_handler.make_keeper_tool_handler
              ~name:"masc_keeper_msg"
              ~input_schema:(keeper_msg_input_schema ())
              ~config
              ~meta
              ~publication_recovery
              ~ctx_snapshot:(make_ctx ())
              ~exec_cache:None
              ()
          in
          let result =
            handler
              (`Assoc
                [
                  ("name", `String "keeper-target");
                  ("message", `String "hello");
                ])
          in
          check bool "handler succeeds" true (Tool_result.is_success result);
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
      Some
        (tool_ok ~tool_name:name
           (Yojson.Safe.to_string
              (`Assoc
                [ ("ok", `Bool true)
                ; ("tool", `String name)
                ; ("route", `String "registered")
                ]))))

let workflow_rejection_probe_tool = "test_keeper_workflow_rejection_probe"

let register_workflow_rejection_probe () =
  register_probe_schema workflow_rejection_probe_tool;
  Tool_dispatch.register
    ~tool_name:workflow_rejection_probe_tool
    ~handler:(fun ~name ~args:_ ->
      Some
        (Tool_result.error
           ~failure_class:(Some Tool_result.Workflow_rejection)
           ~tool_name:name
           ~start_time:(Unix.gettimeofday ())
           workflow_rejection_message))

let register_typed_outcome_probe name make_result =
  register_probe_schema name;
  Tool_dispatch.register
    ~tool_name:name
    ~handler:(fun ~name ~args:_ -> Some (make_result name))
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
      ~exec_cache:None
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
    (outcome_label result.outcome);
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
    (outcome_label result.outcome);
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
    (outcome_label result.outcome);
  check string "success-looking failure payload preserved" raw result.raw_output;
  (match result.outcome with
   | `Failure class_ ->
     check string "typed failure class preserved" "workflow_rejection"
       (Tool_result.tool_failure_class_to_string class_)
   | `Success -> fail "expected typed producer failure")
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
        (match execution.outcome with
         | Masc.Keeper_tool_execution.Failed Tool_result.Workflow_rejection -> ()
         | Masc.Keeper_tool_execution.Failed class_ ->
           fail
             ("unexpected failure class: "
              ^ Tool_result.tool_failure_class_to_string class_)
         | Masc.Keeper_tool_execution.Succeeded -> fail "expected typed failure");
        check bool "error message preserved" true
          (contains_substring execution.raw_output "Self-approval"))

(* ── OAS descriptor execution mode ───────────────────────────

   WebSearch/WebFetch hit external rate-limited APIs. They must not be
   assigned an inferred execution mode merely because they are read-only. *)

let make_dummy_oas_tool name =
  Masc.Tool_bridge.oas_tool_of_masc
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
  let tool = make_dummy_oas_tool name in
  match Agent_sdk.Tool.descriptor tool with
  | None -> ()
  | Some _ -> fail (Printf.sprintf "%s: inferred descriptor for %s" msg name)
;;

let test_catalog_metadata_does_not_infer_oas_descriptors () =
  List.iter
    (fun name -> check_no_inferred_descriptor ~msg:"generic bridge" name)
    [ "masc_web_search"; "masc_web_fetch"; "tool_read_file"; "tool_search_files" ]
;;

let find_tool_by_name tools name =
  List.find_opt
    (fun (t : Agent_sdk.Tool.t) -> String.equal t.Agent_sdk.Tool.schema.Agent_sdk.Types.name name)
    tools
;;

let check_bundle_has_no_inferred_descriptor ~msg tools name =
  match find_tool_by_name tools name with
  | None -> fail (Printf.sprintf "%s: %s not in bundle" msg name)
  | Some t ->
    (match Agent_sdk.Tool.descriptor t with
     | None -> ()
     | Some _ -> fail (Printf.sprintf "%s: %s has inferred descriptor" msg name))
;;

let test_model_visible_tools_do_not_infer_oas_descriptors () =
  with_exec_fixture
    "model_visible_oas_descriptors"
    (fun ~config ~meta ~publication_recovery ~ctx_work:_ ->
       let tools =
         Masc.Keeper_tools_oas_bundle.make_tools
           ~config
           ~meta
           ~publication_recovery
           ~ctx_snapshot:(make_ctx ())
           ()
       in
       List.iter
         (fun name ->
            check_bundle_has_no_inferred_descriptor ~msg:"model-visible" tools name)
         [ "WebSearch"; "WebFetch"; "Grep"; "Read" ])
;;

(* ── Exec cache data structure tests ───────────────────────── *)

let test_exec_cache_stats_json () =
  let cache = Masc_exec.Exec_cache.create () in
  let json = Masc_exec.Exec_cache.to_json cache in
  check int "initial hit_count" 0
    Yojson.Safe.Util.(member "hit_count" json |> to_int);
  check int "initial miss_count" 0
    Yojson.Safe.Util.(member "miss_count" json |> to_int);
  check int "initial entry_count" 0
    Yojson.Safe.Util.(member "entry_count" json |> to_int);
  (* Store an entry and check *)
  Masc_exec.Exec_cache.store cache ~cmd:"test_cmd" ~exit_code:0
    ~output:"test output" ~duration_ms:100;
  let json2 = Masc_exec.Exec_cache.to_json cache in
  check int "after store entry_count" 1
    Yojson.Safe.Util.(member "entry_count" json2 |> to_int);
  (* Lookup triggers a hit *)
  ignore (Masc_exec.Exec_cache.lookup cache "test_cmd");
  let json3 = Masc_exec.Exec_cache.to_json cache in
  check int "after lookup hit_count" 1
    Yojson.Safe.Util.(member "hit_count" json3 |> to_int)

let () =
  Masc_test_deps.init_keeper_tool_registry ();
  run "Keeper_tool_dispatch_runtime" [
    ("execute_keeper_tool_call_with_outcome", [
      test_case "public Read rejects unsupported range fields" `Quick
        test_public_read_rejects_unsupported_range_fields;
      test_case "public Read rejects offset without dispatch enrichment" `Quick
        test_public_read_rejects_offset_without_enrichment;
      test_case "missing file is failure" `Quick
        test_execute_with_outcome_missing_file_is_failure;
      test_case "initializing recovery isolates only publication writes" `Quick
        test_initializing_recovery_isolates_only_publication_writes;
      test_case "Manual Gate defers writes before recovery acquisition" `Quick
        test_manual_gate_defers_publication_writes_before_recovery;
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
      test_case "tool search without session searcher is unavailable" `Quick
        test_tool_search_without_session_searcher_is_unavailable;
      test_case "tool search uses injected session searcher" `Quick
        test_tool_search_uses_exact_injected_searcher;
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
      test_case "public WebFetch reaches localhost after Gate" `Quick
        test_public_masc_web_fetch_reaches_localhost_after_gate;
      test_case "Manual Gate defers web tools before network" `Quick
        test_manual_gate_defers_web_tools_before_network;
      test_case "task FSM errors require explicit failure_class" `Quick
        test_tool_result_does_not_infer_task_fsm_rejections_from_message;
      test_case "tool_result_or_error preserves failure_class" `Quick
        test_tool_result_or_error_preserves_failure_class;
      test_case "tool_execute raw cmd requires typed Shell IR" `Quick
        test_tool_execute_raw_cmd_requires_typed_shell_ir;
      test_case "OAS handler threads Eio context to keeper dispatch" `Quick
        test_oas_handler_threads_eio_context_to_keeper_dispatch;
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
    ]);
    ("exact_registered_dispatch", [
      test_case "raw Board runtime respects typed projection" `Quick
        test_raw_board_runtime_respects_projection;
    ]);
    ("keeper_tools_list_json", [
      test_case "uses typed groups" `Quick
        test_keeper_tools_list_json_uses_typed_groups;
      test_case "descriptor route miss is typed runtime failure" `Quick
        test_descriptor_route_miss_payload_is_typed_runtime_failure;
    ]);
    ("oas_descriptor", [
      test_case "catalog flags do not infer OAS descriptors" `Quick
        test_catalog_metadata_does_not_infer_oas_descriptors;
      test_case "model-visible aliases do not infer OAS descriptors" `Quick
        test_model_visible_tools_do_not_infer_oas_descriptors;
    ]);
    ("exec_cache", [
      test_case "stats json" `Quick test_exec_cache_stats_json;
    ]);
  ]
