(** Coverage tests for Tool_misc *)

open Masc

external unsetenv : string -> unit = "masc_test_unsetenv"

let () = Random.self_init ()
let () = Mirage_crypto_rng_unix.use_default ()
let () =
  Server_startup_state.mark_state_ready ()
  |> Result.get_ok
let () = ignore Dashboard.force_link
let str_contains s sub =
  let len_s = String.length s in
  let len_sub = String.length sub in
  if len_sub > len_s then false
  else
    let rec loop i =
      if i > len_s - len_sub then false
      else if String.sub s i len_sub = sub then true
      else loop (i + 1)
    in
    loop 0

let parse_json s =
  try Yojson.Safe.from_string s
  with Yojson.Json_error err -> failwith ("invalid json: " ^ err)

let json_string_member key = function
  | `Assoc fields ->
      (match List.assoc_opt key fields with
       | Some (`String value) -> value
       | Some _ -> failwith ("json field is not a string: " ^ key)
       | None -> failwith ("missing json field: " ^ key))
  | _ -> failwith "expected json object"

let with_env name value_opt f =
  let original = Sys.getenv_opt name in
  let restore () =
    match original with
    | Some value -> Unix.putenv name value
    | None -> Unix.putenv name ""
  in
  Fun.protect
    ~finally:restore
    (fun () ->
      (match value_opt with
      | Some value -> Unix.putenv name value
      | None -> Unix.putenv name "");
      f ())

let with_unset_env name f =
  let original = Sys.getenv_opt name in
  unsetenv name;
  Fun.protect
    ~finally:(fun () ->
      match original with
      | Some value -> Unix.putenv name value
      | None -> unsetenv name)
    f

let with_boot_override name value_opt f =
  let original = Config_boot_overrides.get_opt name in
  (match value_opt with
   | Some value -> Config_boot_overrides.set name value
   | None -> Config_boot_overrides.clear name);
  Fun.protect
    ~finally:(fun () ->
      match original with
      | Some value -> Config_boot_overrides.set name value
      | None -> Config_boot_overrides.clear name)
    f

let with_isolated_runtime_env f =
  with_env "MASC_BASE_PATH" None (fun () ->
    with_env "MASC_BASE_PATH_INPUT" None f)

(* Test registry — each [test] call appends; final [let ()] dispatches
   via Alcotest.run.  Per-test Eio scope for code paths that use Eio.Mutex. *)
let test_cases : (string * (unit -> unit)) list ref = ref []

let test name f =
  test_cases := (name, fun () ->
    Eio_main.run (fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      with_isolated_runtime_env f)) :: !test_cases

(* Create test context *)
let test_counter = ref 0
let make_test_ctx () =
  incr test_counter;
  let tmp = Filename.concat (Filename.get_temp_dir_name ())
    (Printf.sprintf "masc-misc-test-%d-%d" (int_of_float (Unix.gettimeofday () *. 1000.0)) !test_counter) in
  Unix.mkdir tmp 0o755;
  let config = Workspace.default_config tmp in
  let _ = Workspace.init config ~agent_name:(Some "test-agent") in
  { Tool_misc.config
  ; agent_name = "test-agent"
  ; help_schemas = Config.raw_all_tool_schemas
  }

(* Test dispatch returns None for unknown tool *)
let () = test "dispatch_unknown_tool" (fun () ->
  let ctx = make_test_ctx () in
  let args = `Assoc [] in
  assert (Tool_misc.dispatch ctx ~name:"unknown_tool" ~args = None)
)

let tool_help_description dispatch ctx name =
  match
    dispatch
      ctx
      ~name:"masc_tool_help"
      ~args:(`Assoc [ "tool_name", `String name ])
  with
  | Some result when Tool_result.is_success result ->
    Json_util.get_string (Tool_result.data result) "short_description"
    |> Option.value ~default:""
  | Some result ->
    Alcotest.failf "tool help failed: %s" (Tool_result.message result)
  | None -> Alcotest.fail "masc_tool_help was not dispatched"

let () = test "keeper_tool_help_uses_descriptor_projection" (fun () ->
  let ctx = make_test_ctx () in
  let public_description =
    tool_help_description Tool_misc.dispatch ctx "masc_board_post"
  in
  let keeper_ctx =
    { ctx with help_schemas = Keeper_tool_descriptor.model_visible_schemas () }
  in
  let keeper_description =
    tool_help_description Tool_misc.dispatch keeper_ctx "masc_board_post"
  in
  assert (str_contains public_description "MASC internal board");
  assert (String.equal keeper_description "Create a new board post.");
  assert (not (str_contains keeper_description "`body`"))
)

(* Test dispatch dashboard — may require Eio runtime; skip gracefully if unavailable *)
let () = test "dispatch_dashboard" (fun () ->
  let ctx = make_test_ctx () in
  ignore (Workspace.add_task ctx.config ~title:"default task" ~priority:2 ~description:"");
  Workspace.ensure_workspace_bootstrap ctx.config;
  let second_workspace = ctx.config in
  ignore (Workspace.add_task second_workspace ~title:"second task" ~priority:1 ~description:"");
  let args = `Assoc [] in
  match Tool_misc.dispatch ctx ~name:"masc_dashboard" ~args with
  | Some result ->
      assert (Tool_result.is_success result);
      assert (str_contains (Tool_result.message result) "MASC Dashboard");
      assert (not (str_contains (Tool_result.message result) "second-workspace"));
  | None -> failwith "dispatch returned None"
  | exception Effect.Unhandled _ ->
      Printf.printf "  (skipped: Eio runtime not available)\n"
)

(* Test dispatch dashboard compact — may require Eio runtime *)
let () = test "dispatch_dashboard_compact" (fun () ->
  let ctx = make_test_ctx () in
  let args = `Assoc [("compact", `Bool true)] in
  match Tool_misc.dispatch ctx ~name:"masc_dashboard" ~args with
  | Some result ->
      assert (Tool_result.is_success result);
      assert (str_contains (Tool_result.message result) "MASC [");
      assert (str_contains (Tool_result.message result) "ATTENTION:");
  | None -> failwith "dispatch returned None"
  | exception Effect.Unhandled _ ->
      Printf.printf "  (skipped: Eio runtime not available)\n"
)

let () = test "dispatch_dashboard_current_scope" (fun () ->
  let ctx = make_test_ctx () in
  Workspace.ensure_workspace_bootstrap ctx.config;
  let focused = ctx.config in
  ignore (Workspace.add_task focused ~title:"focus task" ~priority:2 ~description:"");
  let args = `Assoc [("scope", `String "current")] in
  match Tool_misc.dispatch ctx ~name:"masc_dashboard" ~args with
  | Some result ->
      assert (Tool_result.is_success result);
      assert (str_contains (Tool_result.message result) "MASC Dashboard");
      assert (not (str_contains (Tool_result.message result) "focus-workspace"))
  | None -> failwith "dispatch returned None"
  | exception Effect.Unhandled _ ->
      Printf.printf "  (skipped: Eio runtime not available)\n"
)

let () = test "dispatch_keeper_waiting_inventory" (fun () ->
  let ctx = make_test_ctx () in
  Workspace.ensure_workspace_bootstrap ctx.config;
  let args = `Assoc [] in
  match Tool_misc.dispatch ctx ~name:"masc_keeper_waiting_inventory" ~args with
  | Some result ->
      assert (Tool_result.is_success result);
      let data = Tool_result.data result in
      assert
        (String.equal
           (json_string_member "schema" data)
           "masc.dashboard.keeper_waiting_inventory.v3");
      assert
        (String.equal
           (json_string_member "source" data)
           "server_keeper_waiting_inventory")
  | None -> failwith "dispatch returned None"
)

let () = test "dispatch_keeper_waiting_inventory_rejects_unexpected_args" (fun () ->
  let ctx = make_test_ctx () in
  let args = `Assoc [ ("scope", `String "current") ] in
  match Tool_misc.dispatch ctx ~name:"masc_keeper_waiting_inventory" ~args with
  | Some result ->
      assert (not (Tool_result.is_success result));
      assert (Tool_result.failure_class result = Some Tool_result.Workflow_rejection);
      assert
        (Tool_result.message result
         = "masc_keeper_waiting_inventory does not accept arguments: scope")
  | None -> failwith "dispatch returned None"
)

let () = test "dispatch_dashboard_invalid_scope" (fun () ->
  let ctx = make_test_ctx () in
  let args = `Assoc [("scope", `String "everywhere")] in
  match Tool_misc.dispatch ctx ~name:"masc_dashboard" ~args with
  | Some result ->
      assert (not (Tool_result.is_success result));
      assert (str_contains (Tool_result.message result) "Invalid dashboard scope")
  | None -> failwith "dispatch returned None"
)

(* Test dispatch gc — Eio context provided by test helper *)
let () = test "dispatch_gc" (fun () ->
  let ctx = make_test_ctx () in
  let args = `Assoc [("days", `Int 7)] in
  match Tool_misc.dispatch ctx ~name:"masc_gc" ~args with
  | Some result ->
      assert (Tool_result.is_success result);
      assert (String.length (Tool_result.message result) > 0)
  | None -> failwith "dispatch returned None"
)

(* GC has no implicit retention policy. *)
let () = test "dispatch_gc_requires_days" (fun () ->
  let ctx = make_test_ctx () in
  let args = `Assoc [] in
  match Tool_misc.dispatch ctx ~name:"masc_gc" ~args with
  | Some result ->
      assert (not (Tool_result.is_success result));
      assert (str_contains (Tool_result.message result) "days is required")
  | None -> failwith "dispatch returned None"
)

let () = test "dispatch_web_search_requires_query" (fun () ->
  let ctx = make_test_ctx () in
  let args = `Assoc [] in
  match Tool_misc.dispatch ctx ~name:"masc_web_search" ~args with
  | Some result ->
      assert (not (Tool_result.is_success result));
      assert (Tool_result.failure_class result = Some Tool_result.Workflow_rejection);
      assert (Tool_result.message result = "query is required")
  | None -> failwith "dispatch returned None"
)

let () = test "validate_web_search_preserves_opaque_query" (fun () ->
  match
    Tool_misc_web_search.validate_query
      "Authorization: Bearer example-token task-352"
  with
  | Ok query ->
    assert (query = "Authorization: Bearer example-token task-352")
  | Error message -> failwith message
)

let () = test "parse_searxng_json_basic" (fun () ->
  let payload =
    {|{"results": [
        {"title": "OCaml Lang", "url": "https://ocaml.org/", "content": "OCaml programming."},
        {"title": "Example", "url": "https://example.com/", "content": "A page."}
      ]}|}
  in
  let items = Tool_misc.parse_searxng_json payload in
  assert (List.length items = 2);
  match items with
  | (title1, url1, _) :: (title2, url2, _) :: _ ->
      assert (title1 = "OCaml Lang");
      assert (url1 = "https://ocaml.org/");
      assert (title2 = "Example");
      assert (url2 = "https://example.com/")
  | _ -> failwith "expected two parsed items"
)

let () = test "parse_searxng_json_empty_results" (fun () ->
  let payload = {|{"results": []}|} in
  assert (Tool_misc.parse_searxng_json payload = [])
)

let () = test "parse_searxng_json_malformed" (fun () ->
  assert (Tool_misc.parse_searxng_json "not json" = [])
)

let () = test "web_search_provider_plan_includes_searxng_when_configured" (fun () ->
  with_env "OLLAMA_API_KEY" None (fun () ->
  with_env "MASC_SEARXNG_URL" (Some "http://localhost:8888") (fun () ->
    with_env "BRAVE_SEARCH_API_KEY" None (fun () ->
      with_env "TAVILY_API_KEY" None (fun () ->
        with_env "EXA_API_KEY" None (fun () ->
          with_env "BING_SEARCH_API_KEY" None (fun () ->
            with_env "AZURE_BING_SEARCH_API_KEY" None (fun () ->
              with_env "MASC_WEB_SEARCH_PROVIDER" None (fun () ->
                with_env "MASC_WEB_SEARCH_PROVIDER_ORDER" None (fun () ->
                  with_env "MASC_WEB_SEARCH_FALLBACKS" None (fun () ->
                    assert
                      (Tool_misc.web_search_provider_plan ()
                       = [ "searxng" ])))))))))))
)

let () = test "web_search_provider_plan_reads_toml_boot_override" (fun () ->
  with_env "OLLAMA_API_KEY" None (fun () ->
  with_unset_env "MASC_SEARXNG_URL" (fun () ->
    with_boot_override "MASC_SEARXNG_URL" (Some "http://localhost:8888") (fun () ->
      with_env "BRAVE_SEARCH_API_KEY" None (fun () ->
        with_env "TAVILY_API_KEY" None (fun () ->
          with_env "EXA_API_KEY" None (fun () ->
            with_env "BING_SEARCH_API_KEY" None (fun () ->
              with_env "AZURE_BING_SEARCH_API_KEY" None (fun () ->
                with_env "MASC_WEB_SEARCH_PROVIDER" None (fun () ->
                  with_env "MASC_WEB_SEARCH_PROVIDER_ORDER" None (fun () ->
                    with_env "MASC_WEB_SEARCH_FALLBACKS" None (fun () ->
                      assert
                        (Tool_misc.web_search_provider_plan ()
                         = [ "searxng" ]))))))))))))
)

(* Feature contract: with zero credentials the plan is empty and the
   search boundary reports the configuration failure with its remedy —
   never an empty success. *)
let () = test "web_search_provider_plan_empty_without_credentials" (fun () ->
  with_env "OLLAMA_API_KEY" None (fun () ->
  with_env "MASC_SEARXNG_URL" None (fun () ->
    with_env "BRAVE_SEARCH_API_KEY" None (fun () ->
      with_env "TAVILY_API_KEY" None (fun () ->
        with_env "EXA_API_KEY" None (fun () ->
          with_env "BING_SEARCH_API_KEY" None (fun () ->
            with_env "AZURE_BING_SEARCH_API_KEY" None (fun () ->
              with_env "MASC_WEB_SEARCH_PROVIDER" None (fun () ->
                with_env "MASC_WEB_SEARCH_PROVIDER_ORDER" None (fun () ->
                  with_env "MASC_WEB_SEARCH_FALLBACKS" None (fun () ->
                    assert (Tool_misc.web_search_provider_plan () = []);
                    let result =
                      Tool_misc.web_search_simulate_for_test
                        ~query:"ocaml eio" ~limit:3 []
                    in
                    assert (not (Tool_result.is_success result));
                    (* Nothing was called, so nothing crashed: what is
                       missing is configuration. Reported as a fault, the
                       bridge lowers it to [Unknown] and the model retries a
                       call no retry can fix. *)
                    assert
                      (Tool_result.failure_class result
                       = Some Tool_result.Dependency_unavailable);
                    assert
                      (str_contains
                         (Tool_result.message result)
                         "no web search provider is configured");
                    (* The real dispatch path must hit search_impl's own
                       empty-chain branch — the simulator above is a twin
                       loop, not the production one. With an empty plan
                       the loop terminates before any HTTP call and
                       failures are never cached. *)
                    let ctx = make_test_ctx () in
                    (match
                       Tool_misc.dispatch ctx ~name:"masc_web_search"
                         ~args:(`Assoc [ ("query", `String "empty chain probe") ])
                     with
                     | Some dispatched ->
                         assert (not (Tool_result.is_success dispatched));
                         assert
                           (Tool_result.failure_class dispatched
                            = Some Tool_result.Dependency_unavailable);
                         assert
                           (str_contains
                              (Tool_result.message dispatched)
                              "no web search provider is configured")
                     | None -> failwith "masc_web_search was not dispatched")))))))))))
)

let () = test "web_search_provider_plan_prefers_configured_official_provider" (fun () ->
  with_env "OLLAMA_API_KEY" None (fun () ->
  with_env "MASC_SEARXNG_URL" None (fun () ->
    with_env "BRAVE_SEARCH_API_KEY" (Some "brave-key") (fun () ->
      with_env "TAVILY_API_KEY" None (fun () ->
        with_env "EXA_API_KEY" None (fun () ->
          with_env "BING_SEARCH_API_KEY" None (fun () ->
            with_env "AZURE_BING_SEARCH_API_KEY" None (fun () ->
              with_env "MASC_WEB_SEARCH_PROVIDER" (Some "brave") (fun () ->
                with_env "MASC_WEB_SEARCH_FALLBACKS" (Some "tavily,exa") (fun () ->
                  with_env "MASC_WEB_SEARCH_PROVIDER_ORDER" None (fun () ->
                    assert
                      (Tool_misc.web_search_provider_plan ()
                       = [ "brave"; "tavily"; "exa" ])))))))))))
)

let () = test "parse_brave_llm_context_json" (fun () ->
  let payload =
    {|{"grounding":{"generic":[
        {"url":"https://example.com/effects",
         "title":"Effect Handlers",
         "snippets":["OCaml 5 introduces effect handlers.","| Table row | data |"]},
        {"url":"javascript:alert(1)",
         "title":"Invalid scheme",
         "snippets":["dropped"]},
        {"url":"https://example.com/untitled",
         "snippets":["Title falls back to the url."]},
        {"url":"https://example.com/empty","title":"No snippets","snippets":[]}
      ],"map":[]},
      "sources":{"https://example.com/effects":{"title":"Effect Handlers","hostname":"example.com"}}}|}
  in
  match Tool_misc.parse_brave_llm_context_json payload with
  | [ (url1, title1, snippets1); (url2, title2, snippets2) ] ->
      assert (url1 = "https://example.com/effects");
      assert (title1 = "Effect Handlers");
      assert (snippets1 = [ "OCaml 5 introduces effect handlers."; "| Table row | data |" ]);
      assert (url2 = "https://example.com/untitled");
      assert (title2 = "https://example.com/untitled");
      assert (snippets2 = [ "Title falls back to the url." ])
  | entries ->
      failwith
        (Printf.sprintf "expected two grounded entries, got %d" (List.length entries))
)

let () = test "parse_ollama_search_json" (fun () ->
  let payload =
    {|{"results":[
        {"title":"Effect Handlers","url":"https://example.com/effects","content":"OCaml 5 effects."},
        {"title":"Bad scheme","url":"ftp://example.com/x","content":"dropped"}
      ]}|}
  in
  assert
    (Tool_misc.parse_ollama_search_json payload
     = [ ("Effect Handlers", "https://example.com/effects", "OCaml 5 effects.") ]);
  assert (Tool_misc.parse_ollama_search_json "not json" = [])
)

let () = test "web_search_provider_plan_admits_ollama_with_key" (fun () ->
  with_env "MASC_SEARXNG_URL" None (fun () ->
    with_env "BRAVE_SEARCH_API_KEY" None (fun () ->
      with_env "TAVILY_API_KEY" None (fun () ->
        with_env "EXA_API_KEY" None (fun () ->
          with_env "BING_SEARCH_API_KEY" None (fun () ->
            with_env "AZURE_BING_SEARCH_API_KEY" None (fun () ->
              with_env "MASC_WEB_SEARCH_PROVIDER" None (fun () ->
                with_env "MASC_WEB_SEARCH_PROVIDER_ORDER" None (fun () ->
                  with_env "MASC_WEB_SEARCH_FALLBACKS" None (fun () ->
                    with_env "OLLAMA_API_KEY" (Some "ollama-key") (fun () ->
                      assert
                        (Tool_misc.web_search_provider_plan () = [ "ollama" ])))))))))))
)

let () = test "parse_brave_llm_context_json_malformed" (fun () ->
  assert (Tool_misc.parse_brave_llm_context_json "not json" = []);
  assert (Tool_misc.parse_brave_llm_context_json {|{"grounding":{}}|} = [])
)

let () = test "web_search_provider_plan_admits_brave_llm_context_only_explicitly" (fun () ->
  with_env "OLLAMA_API_KEY" None (fun () ->
  with_env "MASC_SEARXNG_URL" None (fun () ->
    with_env "BRAVE_SEARCH_API_KEY" (Some "brave-key") (fun () ->
      with_env "TAVILY_API_KEY" None (fun () ->
        with_env "EXA_API_KEY" None (fun () ->
          with_env "BING_SEARCH_API_KEY" None (fun () ->
            with_env "AZURE_BING_SEARCH_API_KEY" None (fun () ->
              with_env "MASC_WEB_SEARCH_PROVIDER_ORDER" None (fun () ->
                with_env "MASC_WEB_SEARCH_FALLBACKS" None (fun () ->
                  with_env "MASC_WEB_SEARCH_PROVIDER" None (fun () ->
                    (* Default order never contains the grounded provider. *)
                    assert (Tool_misc.web_search_provider_plan () = [ "brave" ]));
                  with_env "MASC_WEB_SEARCH_PROVIDER" (Some "brave_llm_context")
                    (fun () ->
                      assert
                        (Tool_misc.web_search_provider_plan ()
                         = [ "brave_llm_context"; "brave" ])))))))))))
)

(* Feature contract: a grounded provider answer flows through dispatch as
   grounded=true + context_text + sources, with no results rows and no
   client-side truncation of the request-budgeted content. *)
let () = test "dispatch_web_search_grounded_envelope" (fun () ->
  let ctx = make_test_ctx () in
  let query = "grounded envelope contract" in
  Tool_misc.with_web_search_simulation_for_test
    ~outcomes:
      [ ( "brave_llm_context"
        , `Grounded
            [ ( "https://example.com/effects"
              , "Effect Handlers"
              , [ "OCaml 5 introduces effect handlers."; "Second chunk." ] )
            ] )
      ]
    (fun () ->
      let args = `Assoc [ ("query", `String query); ("limit", `Int 3) ] in
      match Tool_misc.dispatch ctx ~name:"masc_web_search" ~args with
      | Some result ->
          assert (Tool_result.is_success result);
          let json = parse_json (Tool_result.message result) in
          let open Yojson.Safe.Util in
          let result_json = json |> member "result" in
          assert (result_json |> member "grounded" |> to_bool);
          assert (result_json |> member "engine" |> to_string = "brave_llm_context");
          assert (result_json |> member "result_count" |> to_int = 1);
          assert (result_json |> member "results" = `Null);
          let context_text = result_json |> member "context_text" |> to_string in
          assert (str_contains context_text "WebSearch grounded context");
          assert (str_contains context_text ("Query: " ^ query));
          assert (str_contains context_text "1. Effect Handlers");
          assert (str_contains context_text "URL: https://example.com/effects");
          assert (str_contains context_text "- OCaml 5 introduces effect handlers.");
          assert (str_contains context_text "- Second chunk.");
          (match result_json |> member "sources" with
           | `List [ source ] ->
               assert (source |> member "url" |> to_string = "https://example.com/effects");
               assert (source |> member "title" |> to_string = "Effect Handlers");
               assert (source |> member "snippet_count" |> to_int = 2)
           | other ->
               failwith ("expected one source, got: " ^ Yojson.Safe.to_string other))
      | None -> failwith "dispatch returned None")
)

let () = test "web_search_simulate_for_test_falls_back_after_error" (fun () ->
  let result =
    Tool_misc.web_search_simulate_for_test ~query:"ocaml eio" ~limit:3
      [
        ("brave", `Error "provider failed");
        ("searxng", `Hits [ ("Eio", "https://example.com/eio", "Fiber runtime") ]);
      ]
  in
  assert (Tool_result.is_success result);
  let json = parse_json ((Tool_result.message result)) in
  let result_json = Yojson.Safe.Util.member "result" json in
  assert (Yojson.Safe.Util.member "engine" result_json = `String "searxng");
  assert (Yojson.Safe.Util.member "result_count" result_json = `Int 1)
)

let () = test "web_search_simulate_for_test_reports_all_failures" (fun () ->
  let result =
    Tool_misc.web_search_simulate_for_test ~query:"ocaml eio" ~limit:3
      [ ("brave", `Empty); ("exa", `Error "provider unavailable") ]
  in
  assert (not (Tool_result.is_success result));
  assert (Tool_result.failure_class result = Some Tool_result.Runtime_failure);
  assert
    (str_contains (Tool_result.message result) "exa: provider unavailable")
)

let () = test "web_search_provider_error_to_string_renders_typed_variants" (fun () ->
  assert
    (Tool_misc.web_search_provider_error_to_string
       (Masc.Tool_misc_web_search.Transport "connection reset")
     = "transport: connection reset");
  assert
    (Tool_misc.web_search_provider_error_to_string
       (Masc.Tool_misc_web_search.Server "HTTP 503")
     = "server: HTTP 503");
  assert
    (Tool_misc.web_search_provider_error_to_string
       (Masc.Tool_misc_web_search.Config "missing API key")
     = "config: missing API key");
  assert
    (Tool_misc.web_search_provider_error_to_string
       (Masc.Tool_misc_web_search.Parse "invalid JSON")
     = "parse: invalid JSON")
)

let () = test "web_search_simulate_for_test_typed_error_renders_prefix" (fun () ->
  let result =
    Tool_misc.web_search_simulate_for_test ~query:"ocaml eio" ~limit:3
      [ ("brave", `Error "connection reset") ]
  in
  assert (not (Tool_result.is_success result));
  assert (Tool_result.failure_class result = Some Tool_result.Runtime_failure);
  assert
    (str_contains (Tool_result.message result) "brave: connection reset")
)

let () = test "dispatch_web_search_include_content_enriches_results" (fun () ->
  let ctx = make_test_ctx () in
  let query = "include content enrichment regression" in
  let url = "https://example.com/masc-web-search-content" in
  let html =
    {|<!doctype html>
<html>
  <head><title>Result Page &amp; Proof</title></head>
  <body>
    <article>
      <h1>Result Page</h1>
      <p>Readable <b>page</b> content &amp; proof.</p>
      <a title="1 > 0" href="https://example.com/standards">Standards &copy;</a>
    </article>
  </body>
</html>|}
  in
  Tool_misc.with_web_search_simulation_for_test
    ~outcomes:[ ("searxng", `Hits [ ("Result", url, "Snippet") ]) ]
    (fun () ->
      Tool_misc.with_web_fetch_http_get_for_test
        (fun ~timeout_sec ~headers:_ ~max_response_bytes url_arg ->
           assert (timeout_sec = 9);
           assert (max_response_bytes = 2_000_000);
           assert (url_arg = url);
           Ok (Some 200, html))
        (fun () ->
          let args =
            `Assoc
              [ ("query", `String query)
              ; ("limit", `Int 1)
              ; ("includeContent", `Bool true)
              ; ("contentMaxChars", `Int 300)
              ; ("contentTimeout", `Int 9)
              ]
          in
          match Tool_misc.dispatch ctx ~name:"masc_web_search" ~args with
          | Some result ->
              assert (Tool_result.is_success result);
              let json = parse_json (Tool_result.message result) in
              let open Yojson.Safe.Util in
              let result_json = json |> member "result" in
              assert (result_json |> member "content_enriched" |> to_bool);
              assert (result_json |> member "content_result_count" |> to_int = 1);
              assert (result_json |> member "content_error_count" |> to_int = 0);
              assert (result_json |> member "content_max_chars" |> to_int = 300);
              assert (result_json |> member "content_timeout" |> to_int = 9);
              let hits = result_json |> member "results" |> to_list in
              assert (List.length hits = 1);
              let hit = List.hd hits in
              let content_text = result_json |> member "content_text" |> to_string in
              assert (str_contains content_text "WebSearch readable results");
              assert (str_contains content_text ("Query: " ^ query));
              assert (str_contains content_text "1. Result");
              assert (str_contains content_text ("URL: " ^ url));
              assert (str_contains content_text "Snippet: Snippet");
              assert (str_contains content_text "Content status: ok (http=200");
              assert (str_contains content_text "Readable page content & proof.");
              assert
                (str_contains content_text
                   "[Standards ©](https://example.com/standards)");
              (* Single-carriage contract: fetched bodies ride only in
                 content_text, never mirrored into per-hit fields. *)
              assert (hit |> member "page_content" = `Null);
              assert (hit |> member "page_content_status" = `Null);
              assert (hit |> member "page_content_http_status" = `Null)
          | None -> failwith "dispatch returned None"))
)

let () = test "dispatch_web_search_include_content_keeps_result_on_fetch_error" (fun () ->
  let ctx = make_test_ctx () in
  let query = "include content fetch failure regression" in
  let url = "https://example.com/masc-web-search-fetch-failure" in
  Tool_misc.with_web_search_simulation_for_test
    ~outcomes:[ ("searxng", `Hits [ ("Result", url, "Snippet") ]) ]
    (fun () ->
      Tool_misc.with_web_fetch_http_get_for_test
        (fun ~timeout_sec:_ ~headers:_ ~max_response_bytes:_ url_arg ->
           assert (url_arg = url);
           Error "network unavailable")
        (fun () ->
          let args =
            `Assoc
              [ ("query", `String query)
              ; ("limit", `Int 1)
              ; ("includeContent", `Bool true)
              ]
          in
          match Tool_misc.dispatch ctx ~name:"masc_web_search" ~args with
          | Some result ->
              assert (Tool_result.is_success result);
              let json = parse_json (Tool_result.message result) in
              let open Yojson.Safe.Util in
              let result_json = json |> member "result" in
              assert (result_json |> member "content_enriched" |> to_bool);
              assert (result_json |> member "content_result_count" |> to_int = 0);
              assert (result_json |> member "content_error_count" |> to_int = 1);
              let hit =
                result_json |> member "results" |> to_list |> List.hd
              in
              let content_text = result_json |> member "content_text" |> to_string in
              assert (str_contains content_text "WebSearch readable results");
              assert (str_contains content_text ("Query: " ^ query));
              assert (str_contains content_text ("URL: " ^ url));
              assert (str_contains content_text "Content status: error");
              assert (str_contains content_text "_Failed to retrieve page content:");
              assert (str_contains content_text ("Source: " ^ url));
              (* Failure detail also rides only in content_text. *)
              assert (hit |> member "page_content" = `Null);
              assert (hit |> member "page_content_status" = `Null);
              assert (hit |> member "page_content_error" = `Null)
          | None -> failwith "dispatch returned None"))
)

(* Pins the named default (was inline 30.0): a keeper research loop must
   be able to repeat a query inside one 15-minute window without paying
   the provider again. *)
let () = test "web_search_cache_ttl_default_is_fifteen_minutes" (fun () ->
  with_boot_override "MASC_WEB_SEARCH_CACHE_TTL_SEC" None (fun () ->
    with_env "MASC_WEB_SEARCH_CACHE_TTL_SEC" None (fun () ->
      assert (Env_config.Tools.web_search_cache_ttl_sec () = 900.0)))
)

let () = test "parse_official_provider_json_payloads" (fun () ->
  let brave =
    Tool_misc.parse_brave_json
      {|{"web":{"results":[{"title":"Brave title","url":"https://example.com/brave","description":"Brave snippet"}]}}|}
  in
  let tavily =
    Tool_misc.parse_tavily_json
      {|{"results":[{"title":"Tavily title","url":"https://example.com/tavily","content":"Tavily snippet"}]}|}
  in
  let exa =
    Tool_misc.parse_exa_json
      {|{"results":[{"title":"Exa title","url":"https://example.com/exa","text":"Exa snippet"}]}|}
  in
  let bing =
    Tool_misc.parse_bing_search_json
      {|{"webPages":{"value":[{"name":"Bing title","url":"https://example.com/bing","snippet":"Bing snippet"}]}}|}
  in
  assert (brave = [ ("Brave title", "https://example.com/brave", "Brave snippet") ]);
  assert (tavily = [ ("Tavily title", "https://example.com/tavily", "Tavily snippet") ]);
  assert (exa = [ ("Exa title", "https://example.com/exa", "Exa snippet") ]);
  assert (bing = [ ("Bing title", "https://example.com/bing", "Bing snippet") ])
)

let () = test "parse_official_provider_json_payloads_tolerate_malformed_json" (fun () ->
  assert (Tool_misc.parse_brave_json {|{"web":|} = []);
  assert (Tool_misc.parse_tavily_json {|{"results": "oops"}|} = []);
  assert (Tool_misc.parse_exa_json {|{"results": [}|} = []);
  assert (Tool_misc.parse_bing_search_json {|{"webPages": "oops"}|} = [])
)

let () = test "redact_transport_error_detail" (fun () ->
  assert
    (Tool_misc.redact_transport_error_detail
       "curl exit code 6 for https://example.com?q=test"
     = "curl exit code 6");
  assert
    (Tool_misc.redact_transport_error_detail "provider request failed"
     = "provider request failed");
  assert (Tool_misc.redact_transport_error_detail "" = "");
  assert
    (Tool_misc.redact_transport_error_detail "forbidden response"
     = "forbidden response")
)

(* Test helper functions *)
let () = test "get_int_present" (fun () ->
  let args = `Assoc [("key", `Int 42)] in
  assert (Tool_args.get_int args "key" 0 = 42)
)

let () = test "get_int_missing" (fun () ->
  let args = `Assoc [] in
  assert (Tool_args.get_int args "key" 99 = 99)
)

let () = test "get_bool_true" (fun () ->
  let args = `Assoc [("key", `Bool true)] in
  assert (Tool_args.get_bool args "key" false = true)
)

let () = test "get_bool_false" (fun () ->
  let args = `Assoc [("key", `Bool false)] in
  assert (Tool_args.get_bool args "key" true = false)
)

let () = test "get_bool_missing" (fun () ->
  let args = `Assoc [] in
  assert (Tool_args.get_bool args "key" true = true)
)

let () = test "get_string_present" (fun () ->
  let args = `Assoc [("key", `String "value")] in
  assert (Tool_args.get_string args "key" "default" = "value")
)

let () = test "get_string_missing" (fun () ->
  let args = `Assoc [] in
  assert (Tool_args.get_string args "key" "default" = "default")
)

(* --- waiting-inventory grouping: a consumption-stalled keeper's pending wall
   collapses per conversation/urgency instead of per message. RFC-0377 drains
   a same-conversation backlog in one turn, so the aggregate loses no operator
   decision: the oldest member keeps the row address ([source_ref],
   [event_id]) and every member id rides in [detail]. --- *)

let json_int_member key = function
  | `Assoc fields ->
      (match List.assoc_opt key fields with
       | Some (`Int value) -> value
       | Some _ -> failwith ("json field is not an int: " ^ key)
       | None -> failwith ("missing json field: " ^ key))
  | _ -> failwith "expected json object"

let connector_selection ~event_id ~arrived_at =
  let channel =
    Keeper_continuation_channel.discord
      ~guild_id:(Some "guild-1")
      ~channel_id:"chan-1"
      ~parent_channel_id:None
      ~thread_id:None
      ~user_id:"user-1"
      ()
    |> Result.get_ok
  in
  { Keeper_event_queue_state.source =
      { Keeper_event_queue.post_id = "post-" ^ event_id
      ; urgency = Keeper_event_queue.Low
      ; arrived_at
      ; payload =
          Keeper_event_queue.Connector_attention { event_id; channel }
      }
  ; admitted_revision = 1L
  }

let () =
  test "waiting_inventory_groups_connector_attention_stimuli" (fun () ->
    let bootstrap_selection =
      { Keeper_event_queue_state.source =
          { Keeper_event_queue.post_id = "post-boot"
          ; urgency = Keeper_event_queue.Normal
          ; arrived_at = 5.0
          ; payload = Keeper_event_queue.Bootstrap
          }
      ; admitted_revision = 1L
      }
    in
    let rows =
      Server_keeper_waiting_inventory.For_testing.rows_for_queue_snapshot
        ~keeper_name:"group-fixture"
        ~source:Server_keeper_waiting_inventory.Event_queue_pending
        ~next_action:"keeper_cycle"
        (connector_selection ~event_id:"evt-b" ~arrived_at:20.0
        :: connector_selection ~event_id:"evt-a" ~arrived_at:10.0
        :: bootstrap_selection
        :: connector_selection ~event_id:"evt-c" ~arrived_at:30.0
        :: [])
    in
    assert (List.length rows = 2);
    let grouped = List.hd rows in
    assert (String.equal grouped.what "외부 메시지 도착 ×3 (낮은 우선순위)");
    assert (grouped.since = Some 10.0);
    assert (json_int_member "group_count" grouped.detail = 3);
    (* Member event ids are sorted so the aggregate is stable across queue
       order. *)
    (match grouped.detail with
     | `Assoc fields ->
         (match List.assoc_opt "group_event_ids" fields with
          | Some (`List ids) ->
              assert (List.length ids = 3);
              assert (
                ids
                = [ `String "evt-a"; `String "evt-b"; `String "evt-c" ])
          | _ -> failwith "missing group_event_ids")
     | _ -> failwith "expected json object");
    (* The non-Connector stimulus keeps its own row. *)
    let other = List.nth rows 1 in
    assert (String.equal other.what "기동 직후 첫 턴"))

let () =
  test "waiting_inventory_single_connector_stays_individual" (fun () ->
    let rows =
      Server_keeper_waiting_inventory.For_testing.rows_for_queue_snapshot
        ~keeper_name:"group-fixture"
        ~source:Server_keeper_waiting_inventory.Event_queue_pending
        ~next_action:"keeper_cycle"
        [ connector_selection ~event_id:"evt-solo" ~arrived_at:10.0 ]
    in
    assert (List.length rows = 1);
    let row = List.hd rows in
    assert (String.equal row.what "외부 메시지 도착 (낮은 우선순위)");
    (match row.detail with
     | `Assoc fields -> assert (List.assoc_opt "group_count" fields = None)
     | _ -> failwith "expected json object"))

let () =
  Alcotest.run "Tool_misc"
    [
      ( "coverage",
        List.rev !test_cases
        |> List.map (fun (name, f) -> Alcotest.test_case name `Quick f) );
    ]

let () = exit 0
