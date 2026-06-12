open Alcotest

module KET = Masc.Keeper_tool_dispatch_runtime
module KES = Masc.Keeper_tool_shared_runtime
module Workspace = Masc.Workspace

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

let make_meta ?(name = "keeper-exec-tools") ?(policy_voice_enabled = false) ?tool_access () =
  let tool_access =
    match tool_access with
    | Some value -> value
    | None ->
        []
  in
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [
          ("name", `String name);
          ("agent_name", `String name);
          ("trace_id", `String "keeper-exec-tools-trace");
          ("allowed_paths", `List [ `String "*" ]);
          ("policy_voice_enabled", `Bool policy_voice_enabled);
          ( "tool_access",
            Json_util.json_string_list tool_access );
        ])
  with
  | Ok meta -> meta
  | Error err -> failwith ("make_meta failed: " ^ err)

let make_ctx () =
  Masc.Keeper_context_runtime.create ~system_prompt:"test" ~max_tokens:4000

let with_exec_fixture ?(process = false) ?tool_access name fn =
  let dir = temp_dir name in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      if process
      then
        Process_eio.init
          ~cwd_default:Eio.Path.(Eio.Stdenv.fs env / dir)
          ~proc_mgr:(Eio.Stdenv.process_mgr env)
          ~clock:(Eio.Stdenv.clock env);
      let config = Masc.Workspace.default_config dir in
      let meta = make_meta ?tool_access () in
      ignore (Masc.Keeper_registry.register ~base_path:config.base_path meta.name meta);
      Fun.protect
        ~finally:(fun () ->
          Masc.Keeper_registry.unregister ~base_path:config.base_path meta.name)
        (fun () -> fn ~config ~meta ~ctx_work:(make_ctx ())))

let payload_kind = function
  | KET.Structured_success -> "structured_success"
  | KET.Structured_error -> "structured_error"
  | KET.Plain_text -> "plain_text"
  | KET.Malformed_structured _ -> "malformed_structured"

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
  | `Failure -> "failure"

let non_empty_lines text =
  String.split_on_char '\n' text
  |> List.map String.trim
  |> List.filter (fun line -> line <> "")

let check_kind ~msg expected payload =
  check string msg expected
    (payload_kind (KET.classify_tool_result_payload payload))

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
  check string (label ^ " payload shape") "structured_success"
    (payload_kind result.KET.payload_shape);
  let json = Yojson.Safe.from_string result.KET.raw_output in
  check bool (label ^ " ok") true (json_bool_field ~default:false "ok" json);
  json

let test_plain_text_is_success_shape () =
  check_kind
    ~msg:"plain text stays plain_text"
    "plain_text"
    "## Search Results\n\n- tool_read_file"

let test_plain_text_with_leading_whitespace_stays_plain () =
  check_kind
    ~msg:"leading whitespace plain text stays plain_text"
    "plain_text"
    "  completed successfully"

let test_structured_success_json () =
  check_kind
    ~msg:"ok=true object is structured_success"
    "structured_success"
    {|{"ok":true,"result":"done"}|}

let test_structured_error_json () =
  check_kind
    ~msg:"error object is structured_error"
    "structured_error"
    {|{"ok":false,"error":"boom"}|}

let test_structured_array_counts_as_success_shape () =
  check_kind
    ~msg:"json array remains structured_success"
    "structured_success"
    {|[{"task_id":"T-1"}]|}

let test_malformed_json_like_payload_detected () =
  match KET.classify_tool_result_payload {|{"ok":true|} with
  | KET.Malformed_structured detail ->
    check bool "detail mentions JSON parse error"
      true (String.length detail > 0)
  | other ->
    fail
      (Printf.sprintf "expected malformed_structured, got %s"
         (payload_kind other))

let test_registered_descriptor_bypasses_tool_access_allowlist () =
  with_exec_fixture
    ~tool_access:([ "keeper_tools_list" ])
    "keeper_tool_dispatch_runtime_descriptor_bypass"
    (fun ~config ~meta ~ctx_work ->
      let result =
        KET.execute_keeper_tool_call_with_outcome
          ~config ~meta ~ctx_work ~exec_cache:None
          ~name:"Read"
          ~input:(`Assoc [ ("file_path", `String "blocked.txt") ])
          ()
      in
      check string "runtime outcome" "failure"
        (match result.outcome with `Success -> "success" | `Failure -> "failure");
      check string "runtime payload shape" "structured_error"
        (payload_kind result.payload_shape);
      let json = Yojson.Safe.from_string result.raw_output in
      check bool "did not stop at tool_access allowlist gate" false
        Yojson.Safe.Util.(member "error" json |> to_string = "tool_not_allowed");
      check bool "reached file runtime" true
        (match Yojson.Safe.Util.member "path_resolution" json with
         | `Assoc _ -> true
         | _ -> false))

let test_public_read_rejects_unsupported_range_fields () =
  with_exec_fixture
    "keeper_tool_dispatch_runtime_read_rejects_range_fields"
    (fun ~config ~meta ~ctx_work ->
      let result =
        KET.execute_keeper_tool_call_with_outcome
          ~config
          ~meta
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
        (match result.outcome with `Success -> "success" | `Failure -> "failure");
      check string "runtime payload shape" "structured_error"
        (payload_kind result.payload_shape);
      let json = Yojson.Safe.from_string result.raw_output in
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
      check bool "did not reach file runtime" false
        (match Yojson.Safe.Util.member "path_resolution" json with
         | `Assoc _ -> true
         | _ -> false))

let counter_for_tool_not_allowed ~keeper ~tool ~reason =
  Masc.Otel_metric_store.metric_value_or_zero
    Keeper_metrics.(to_string ToolNotAllowed)
    ~labels:[ ("keeper", keeper); ("tool", tool); ("reason", reason) ]
    ()

(* #13xxx: tool_not_allowed Otel_metric_store counter *)
let test_tool_not_allowed_increments_counter_for_unknown_tool () =
  (* Unknown names are still rejected by the descriptor/registry existence
     gate. Registered tools are not rejected merely because tool_access is
     narrow or empty. *)
  let keeper = "test-exec-tools-not-allowed-a" in
  let tool = "keeper_not_a_real_tool" in
  let reason = "not_in_candidate_set" in
  with_exec_fixture
    ~tool_access:([ "keeper_tools_list" ])
    "keeper_tool_dispatch_runtime_not_allowed_counter"
    (fun ~config ~meta ~ctx_work ->
      let before = counter_for_tool_not_allowed ~keeper ~tool ~reason in
      ignore
        (KET.execute_keeper_tool_call_with_outcome
           ~config
           ~meta:{ meta with name = keeper }
           ~ctx_work ~exec_cache:None
           ~name:tool
           ~input:(`Assoc [])
           ());
      check (float 0.0001) "not_in_candidate_set counter +1"
        (before +. 1.0)
        (counter_for_tool_not_allowed ~keeper ~tool ~reason))

let test_tool_not_allowed_denied_by_policy_counter () =
  (* A keeper whose denylist contains keeper_board_post should land in
     reason=denied_by_policy. *)
  let keeper = "test-exec-tools-not-allowed-b" in
  let tool = "keeper_board_post" in
  let reason = "denied_by_policy" in
  (* Build meta that has board_post in the allowlist but also on the denylist
     so can_execute returns false via the deny-set path. *)
  let meta_with_deny =
    match
      Masc_test_deps.meta_of_json_fixture
        (`Assoc
          [ ("name", `String keeper)
          ; ("agent_name", `String keeper)
          ; ("trace_id", `String "test-not-allowed-b")
          ; ("allowed_paths", `List [ `String "*" ])
          ; ( "tool_access"
            , Json_util.json_string_list
                ([ "keeper_board_post" ]) )
          ; ( "tool_denylist"
            , `List [ `String "keeper_board_post" ] )
          ])
    with
    | Ok m -> m
    | Error e -> failwith ("meta_of_json_fixture: " ^ e)
  in
  let dir =
    let d = Filename.temp_file "keeper_tool_dispatch_not_allowed_b" "" in
    Unix.unlink d; Unix.mkdir d 0o755; d
  in
  let cleanup () =
    let rec rm t =
      if Sys.file_exists t then
        if Sys.is_directory t then begin
          Sys.readdir t |> Array.iter (fun n -> rm (Filename.concat t n));
          Unix.rmdir t
        end else Unix.unlink t
    in
    try rm dir with _ -> ()
  in
  Fun.protect ~finally:cleanup (fun () ->
    Eio_main.run @@ fun env ->
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    let config = Masc.Workspace.default_config dir in
    let before = counter_for_tool_not_allowed ~keeper ~tool ~reason in
    ignore
      (KET.execute_keeper_tool_call_with_outcome
         ~config ~meta:meta_with_deny ~ctx_work:(make_ctx ())
         ~exec_cache:None ~name:tool ~input:(`Assoc []) ());
    check (float 0.0001) "denied_by_policy counter +1"
      (before +. 1.0)
      (counter_for_tool_not_allowed ~keeper ~tool ~reason))

let test_tool_not_allowed_reason_label_is_bounded () =
  (* Verify that the reason label written into the JSON payload is one
     of the three bounded vocabulary values, not a free-form string. *)
  with_exec_fixture
    "keeper_tool_dispatch_runtime_reason_bounded"
    (fun ~config ~meta ~ctx_work ->
      let result =
        KET.execute_keeper_tool_call_with_outcome
          ~config ~meta ~ctx_work ~exec_cache:None
          ~name:"keeper_not_a_real_tool"
          ~input:(`Assoc [])
          ()
      in
      let json = Yojson.Safe.from_string result.raw_output in
      let reason = Yojson.Safe.Util.(member "reason" json |> to_string) in
      let valid = [ "not_in_candidate_set"; "denied_by_policy"; "not_executable" ] in
      check bool "reason label is bounded vocabulary"
        true (List.mem reason valid))

let test_keeper_tools_list_json_uses_typed_groups () =
  let meta =
    make_meta
      ~policy_voice_enabled:true
      ~tool_access:
        (
           [ "keeper_board_post";
             "keeper_board_fake";
             "keeper_voice_speak";
             "keeper_task_claim";
             "keeper_surface_read";
             "tool_search_files";
             "tool_read_file";
             "keeper_memory_search";
             "keeper_tools_list";
           ])
      ()
  in
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
  check bool "surface read grouped as surface" true
    (member "surface" "keeper_surface_read");
  check bool "surface read not hidden under meta" false
    (member "meta" "keeper_surface_read");
  check bool "tools_list remains a meta introspection tool" true
    (member "meta" "keeper_tools_list");
  check bool "Grep tool grouped" true
    (member "search_files" "tool_search_files");
  check bool "fs tool grouped" true
    (member "fs" "tool_read_file");
  check bool "memory tool grouped" true
    (member "memory" "keeper_memory_search")

let test_execute_with_outcome_missing_file_is_failure () =
  with_exec_fixture "keeper_tool_dispatch_runtime_missing_file"
    (fun ~config ~meta ~ctx_work ->
      let repo_dir =
        Filename.concat
          (Filename.concat (KES.keeper_playground_root ~config ~meta) "repos")
          "masc-mcp"
      in
      mkdir_p (Filename.concat repo_dir ".git");
      let result =
        KET.execute_keeper_tool_call_with_outcome
          ~config ~meta ~ctx_work ~exec_cache:None
          ~name:"Read"
          ~input:(`Assoc [ ("file_path", `String "config/tool_policy.toml") ])
          ()
      in
      check string "missing file outcome" "failure"
        (match result.outcome with `Success -> "success" | `Failure -> "failure");
      check string "missing file payload shape" "structured_error"
        (payload_kind result.payload_shape);
      let json = Yojson.Safe.from_string result.raw_output in
      let path_resolution = Yojson.Safe.Util.member "path_resolution" json in
      check string "single repo surfaced" "repos/masc-mcp"
        Yojson.Safe.Util.(member "available_repos" json |> to_list |> List.hd |> to_string);
      check string "repo cwd hint" "repos/masc-mcp"
        Yojson.Safe.Util.(member "repo_cwd_hint" path_resolution |> to_string);
      check bool "same path retry marked as futile" true
        Yojson.Safe.Util.(member "same_path_retry_will_fail" path_resolution |> to_bool);
      check bool "retry policy discourages same Read" true
        (contains_substring
           Yojson.Safe.Util.(member "retry_policy" path_resolution |> to_string)
           "Do not retry Read");
      check string "recovery parent path" "repos/masc-mcp/config"
        Yojson.Safe.Util.(
          member "recovery_examples" path_resolution
          |> member "parent_path_hint"
          |> to_string);
      check string "recovery basename hint" "tool_policy.toml"
        Yojson.Safe.Util.(
          member "recovery_examples" path_resolution
          |> member "basename_hint"
          |> to_string))

let test_execute_with_outcome_bad_query_is_failure () =
  with_exec_fixture "keeper_tool_dispatch_runtime_bad_query"
    (fun ~config ~meta ~ctx_work ->
      let result =
        KET.execute_keeper_tool_call_with_outcome
          ~config ~meta ~ctx_work ~exec_cache:None
          ~name:"keeper_tool_search"
          ~input:(`Assoc [ ("query", `String "") ])
          ()
      in
      check string "bad query outcome" "failure"
        (match result.outcome with `Success -> "success" | `Failure -> "failure");
      check string "bad query payload shape" "structured_error"
        (payload_kind result.payload_shape))

let test_public_local_aliases_dispatch_to_runtime_handlers () =
  with_exec_fixture ~process:true "keeper_tool_dispatch_runtime_public_aliases"
    (fun ~config ~meta ~ctx_work ->
      let playground = KES.keeper_default_write_root ~config ~meta in
      let visible_file_path = "public-alias.txt" in
      let file_path = Filename.concat playground "public-alias.txt" in
      let run name input =
        KET.execute_keeper_tool_call_with_outcome
          ~config
          ~meta
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
        (contains_substring grep_result.raw_output "public-alias.txt");
      check bool "Grep match includes content" true
        (contains_substring grep_result.raw_output "gamma");
      let search_result =
        run
          "Search"
          (`Assoc
             [ "pattern", `String "gamma"; "path", `String visible_file_path ])
      in
      let search_json = check_success_result "Search" search_result in
      check string "Search translates to rg op" "rg"
        (json_string_field ~default:"" "op" search_json);
      check bool "Search returns real match" true
        (contains_substring search_result.raw_output "public-alias.txt");
      check bool "Search match includes content" true
        (contains_substring search_result.raw_output "gamma");
      let execute_result =
        run
          "Execute"
          (`Assoc
             [ "executable", `String "pwd"
             ; "cwd", `String playground
             ; "timeout_sec", `Float 5.0
             ])
      in
      let execute_json = check_success_result "Execute" execute_result in
      check bool "Execute used typed Shell IR" true
        (json_bool_field ~default:false "typed" execute_json);
      check bool "Execute ran in requested cwd" true
        (contains_substring execute_result.raw_output playground))

let test_public_masc_web_search_alias_dispatches_to_misc_runtime () =
  with_exec_fixture "keeper_tool_dispatch_web_search_alias"
    (fun ~config ~meta ~ctx_work ->
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
              ~ctx_work
              ~exec_cache:None
              ~name:"WebSearch"
              ~input:
                (`Assoc
                  [
                    ("query", `String "ocaml eio runtime alias test");
                    ("limit", `Int 3);
                  ])
              ()
          in
          check string "web search alias outcome" "success"
            (outcome_label result.outcome);
          check string "web search alias payload shape" "structured_success"
            (payload_kind result.payload_shape);
          let json = parse_json result.raw_output in
          let result_json = Yojson.Safe.Util.member "result" json in
          check string "status" "ok"
            Yojson.Safe.Util.(member "status" json |> to_string);
          check string "query preserved" "ocaml eio runtime alias test"
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

let test_public_masc_web_fetch_alias_dispatches_to_misc_runtime () =
  with_exec_fixture "keeper_tool_dispatch_web_fetch_alias"
    (fun ~config ~meta ~ctx_work ->
      let requested_url = "https://example.com/alias-web-fetch" in
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
          check string "web fetch alias payload shape" "structured_success"
            (payload_kind result.payload_shape);
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

let test_public_masc_web_fetch_blocks_localhost_before_runtime () =
  with_exec_fixture "keeper_tool_dispatch_web_fetch_blocks_localhost"
    (fun ~config ~meta ~ctx_work ->
      Masc.Tool_misc.with_web_fetch_http_get_for_test
        (fun ~timeout_sec:_ ~headers:_ ~max_response_bytes:_ _url ->
          fail "blocked URL should not reach the HTTP runtime")
        (fun () ->
          let result =
            KET.execute_keeper_tool_call_with_outcome
              ~config
              ~meta
              ~ctx_work
              ~exec_cache:None
              ~name:"WebFetch"
              ~input:(`Assoc [ ("url", `String "http://127.0.0.1:8935/health") ])
              ()
          in
          check string "web fetch local outcome" "failure"
            (outcome_label result.outcome);
          check string "web fetch local payload shape" "structured_error"
            (payload_kind result.payload_shape);
          check bool "blocked host message" true
            (contains_substring result.raw_output "url host is blocked")))

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

let test_workflow_rejection_payload_skips_circuit_breaker () =
  let workflow_payload =
    KES.error_json
      ~fields:[ "failure_class", `String "workflow_rejection" ]
      workflow_rejection_message
  in
  let egress_payload =
    {|{"ok":false,"error":"egress_blocked","failure_class":"policy_rejection","attempted":"localhost","allowed":["*.github.com"]}|}
  in
  let legacy_egress_payload =
    {|{"ok":false,"error":"egress_blocked","attempted":"localhost","allowed":["*.github.com"]}|}
  in
  let runtime_payload =
    KES.error_json
      ~fields:[ "failure_class", `String "runtime_failure" ]
      "No such file or directory"
  in
  check (option string) "extracts workflow class" (Some "workflow_rejection")
    (Option.map Tool_result.tool_failure_class_to_string
       (KET.failure_class_of_tool_result_payload workflow_payload));
  check bool "workflow rejection does not trip circuit breaker" false
    (KET.should_apply_circuit_breaker_to_failure_payload
       (KET.failure_class_of_tool_result_payload workflow_payload));
  check (option string) "extracts egress policy class" (Some "policy_rejection")
    (Option.map Tool_result.tool_failure_class_to_string
       (KET.failure_class_of_tool_result_payload egress_payload));
  check bool "egress policy rejection does not trip circuit breaker" false
    (KET.should_apply_circuit_breaker_to_failure_payload
       (KET.failure_class_of_tool_result_payload egress_payload));
  (* legacy egress has no failure_class field → typed parser defaults to
     Runtime_failure (conservative: unknown → fail, CLAUDE.md anti-pattern #2). *)
  check (option string) "legacy egress defaults to runtime_failure" (Some "runtime_failure")
    (Option.map Tool_result.tool_failure_class_to_string
       (KET.failure_class_of_tool_result_payload legacy_egress_payload));
  check bool "legacy egress still trips circuit breaker" true
    (KET.should_apply_circuit_breaker_to_failure_payload
       (KET.failure_class_of_tool_result_payload legacy_egress_payload));
  check bool "runtime failure still trips circuit breaker" true
    (KET.should_apply_circuit_breaker_to_failure_payload
       (KET.failure_class_of_tool_result_payload runtime_payload))

let test_tool_execute_raw_cmd_requires_typed_shell_ir () =
  with_exec_fixture "tool_execute_raw_cmd_requires_typed_shell_ir"
    (fun ~config ~meta ~ctx_work ->
      let input =
        `Assoc
          [ ( "cmd"
            , `String "cat .masc/state/backlog.json 2>/dev/null | head -5" )
          ]
      in
      let run () =
        KET.execute_keeper_tool_call
          ~config ~meta ~ctx_work ~exec_cache:None
          ~name:"tool_execute" ~input ()
      in
      let raw = run () in
      let json = Yojson.Safe.from_string raw in
      check string "typed shell ir required"
        "Typed Shell IR input is required. Provide executable/argv or pipeline."
        Yojson.Safe.Util.(member "error" json |> to_string);
      check bool "typed marker" true
        Yojson.Safe.Util.(member "typed" json |> to_bool);
      check bool "single hard-cut rejection does not enrich circuit breaker" true
        Yojson.Safe.Util.(member "circuit_breaker" json = `Null))

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

let test_registered_tool_dispatch_without_masc_prefix () =
  register_registered_dispatch_probe ();
  check bool "probe has no masc_ prefix" false
    (String.starts_with ~prefix:"masc_" registered_dispatch_probe_tool);
  with_exec_fixture "keeper_tool_dispatch_registered_dispatch"
    (fun ~config ~meta ~ctx_work:_ ->
      match
        Masc.Keeper_tool_registered_runtime.handle_registered_tool
          ~config
          ~keeper_name:meta.name
          ~name:registered_dispatch_probe_tool
          ~args:(`Assoc [])
      with
      | None -> fail "expected registered keeper tool dispatch"
      | Some raw ->
        let json = Yojson.Safe.from_string raw in
        check string "registered tool name" registered_dispatch_probe_tool
          Yojson.Safe.Util.(member "tool" json |> to_string);
        check string "registered route" "registered"
          Yojson.Safe.Util.(member "route" json |> to_string))

let test_registered_dispatch_preserves_workflow_failure_class () =
  register_workflow_rejection_probe ();
  with_exec_fixture "keeper_tool_dispatch_registered_workflow_rejection"
    (fun ~config ~meta ~ctx_work:_ ->
      match
        Masc.Keeper_tool_registered_runtime.handle_registered_tool
          ~config
          ~keeper_name:meta.name
          ~name:workflow_rejection_probe_tool
          ~args:(`Assoc [])
      with
      | None -> fail "expected registered keeper tool dispatch"
      | Some raw ->
        let json = Yojson.Safe.from_string raw in
        check string "failure class preserved" "workflow_rejection"
          Yojson.Safe.Util.(member "failure_class" json |> to_string);
        check bool "error message preserved" true
          (contains_substring
             Yojson.Safe.Util.(member "error" json |> to_string)
             "Self-approval"))

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
    ("classify_tool_result_payload", [
      test_case "plain text" `Quick test_plain_text_is_success_shape;
      test_case "plain text with leading whitespace" `Quick
        test_plain_text_with_leading_whitespace_stays_plain;
      test_case "structured success object" `Quick
        test_structured_success_json;
      test_case "structured error object" `Quick
        test_structured_error_json;
      test_case "structured array" `Quick
        test_structured_array_counts_as_success_shape;
      test_case "malformed json-like payload" `Quick
        test_malformed_json_like_payload_detected;
    ]);
    ("execute_keeper_tool_call_with_outcome", [
      test_case "registered descriptor bypasses tool_access allowlist" `Quick
        test_registered_descriptor_bypasses_tool_access_allowlist;
      test_case "public Read rejects unsupported range fields" `Quick
        test_public_read_rejects_unsupported_range_fields;
      test_case "missing file is failure" `Quick
        test_execute_with_outcome_missing_file_is_failure;
      test_case "bad query is failure" `Quick
        test_execute_with_outcome_bad_query_is_failure;
      test_case "public local aliases dispatch to runtime handlers" `Quick
        test_public_local_aliases_dispatch_to_runtime_handlers;
      test_case "public WebSearch alias reaches misc runtime" `Quick
        test_public_masc_web_search_alias_dispatches_to_misc_runtime;
      test_case "public WebFetch alias reaches misc runtime" `Quick
        test_public_masc_web_fetch_alias_dispatches_to_misc_runtime;
      test_case "public WebFetch blocks localhost before runtime" `Quick
        test_public_masc_web_fetch_blocks_localhost_before_runtime;
      test_case "task FSM errors require explicit failure_class" `Quick
        test_tool_result_does_not_infer_task_fsm_rejections_from_message;
      test_case "tool_result_or_error preserves failure_class" `Quick
        test_tool_result_or_error_preserves_failure_class;
      test_case "workflow rejection skips circuit breaker" `Quick
        test_workflow_rejection_payload_skips_circuit_breaker;
      test_case "tool_execute raw cmd requires typed Shell IR" `Quick
        test_tool_execute_raw_cmd_requires_typed_shell_ir;
      test_case "registered dispatch does not require masc_ prefix" `Quick
        test_registered_tool_dispatch_without_masc_prefix;
      test_case "registered dispatch preserves workflow failure class" `Quick
        test_registered_dispatch_preserves_workflow_failure_class;
    ]);
    ("tool_not_allowed_counter", [
      test_case "increments for not_in_candidate_set" `Quick
        test_tool_not_allowed_increments_counter_for_unknown_tool;
      test_case "increments for denied_by_policy" `Quick
        test_tool_not_allowed_denied_by_policy_counter;
      test_case "reason label is bounded vocabulary" `Quick
        test_tool_not_allowed_reason_label_is_bounded;
    ]);
    ("keeper_tools_list_json", [
      test_case "uses typed groups" `Quick
        test_keeper_tools_list_json_uses_typed_groups;
    ]);
    ("exec_cache", [
      test_case "stats json" `Quick test_exec_cache_stats_json;
    ]);
  ]
