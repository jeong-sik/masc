(** Coverage tests for Tool_misc *)

open Masc

external unsetenv : string -> unit = "masc_test_unsetenv"

let () = Random.self_init ()
let () = Mirage_crypto_rng_unix.use_default ()
let () = Server_startup_state.mark_state_ready ~backend_mode:"test"
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
  { Tool_misc.config; agent_name = "test-agent" }

(* Test dispatch returns None for unknown tool *)
let () = test "dispatch_unknown_tool" (fun () ->
  let ctx = make_test_ctx () in
  let args = `Assoc [] in
  assert (Tool_misc.dispatch ctx ~name:"unknown_tool" ~args = None)
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
           "masc.dashboard.keeper_waiting_inventory.v1");
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

(* Test dispatch gc with default days *)
let () = test "dispatch_gc_default" (fun () ->
  let ctx = make_test_ctx () in
  let args = `Assoc [] in
  match Tool_misc.dispatch ctx ~name:"masc_gc" ~args with
  | Some result ->
      assert (Tool_result.is_success result);
      assert (String.length (Tool_result.message result) > 0)
  | None -> failwith "dispatch returned None"
)

(* Test dispatch cleanup_zombies *)
let () = test "dispatch_cleanup_zombies" (fun () ->
  let ctx = make_test_ctx () in
  let args = `Assoc [] in
  match Tool_misc.dispatch ctx ~name:"masc_cleanup_zombies" ~args with
  | Some result ->
      assert (Tool_result.is_success result);
      assert (String.length (Tool_result.message result) > 0)
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

let () = test "dispatch_web_search_rejects_long_query" (fun () ->
  let ctx = make_test_ctx () in
  let query = String.make 501 'a' in
  let args = `Assoc [ ("query", `String query) ] in
  match Tool_misc.dispatch ctx ~name:"masc_web_search" ~args with
  | Some result ->
      assert (not (Tool_result.is_success result));
      assert (Tool_result.failure_class result = Some Tool_result.Workflow_rejection);
      assert (Tool_result.message result = "query must be at most 500 characters")
  | None -> failwith "dispatch returned None"
)

let () = test "dispatch_web_search_rejects_secret_like_query" (fun () ->
  let ctx = make_test_ctx () in
  let args = `Assoc [ ("query", `String "Authorization: Bearer secret-token") ] in
  match Tool_misc.dispatch ctx ~name:"masc_web_search" ~args with
  | Some result ->
      assert (not (Tool_result.is_success result));
      assert (Tool_result.failure_class result = Some Tool_result.Workflow_rejection);
      assert
        (Tool_result.message result
         = "query looks like it may contain secrets; refine it before using web search")
  | None -> failwith "dispatch returned None"
)

let () = test "validate_web_search_allows_task_id_with_sk_substring" (fun () ->
  match
    Tool_misc_web_search.validate_query
      "task-352 destructive check tools hardcoded"
  with
  | Ok query -> assert (query = "task-352 destructive check tools hardcoded")
  | Error message -> failwith message
)

let () = test "validate_web_search_rejects_sk_prefixed_secret_token" (fun () ->
  match
    Tool_misc_web_search.validate_query
      "investigate leaked key sk-1234567890abcdefghijklmnop"
  with
  | Ok _ -> failwith "expected secret-like query to be rejected"
  | Error message ->
      assert
        (message
         = "query looks like it may contain secrets; refine it before using web search")
)

let () = test "parse_bing_rss_items" (fun () ->
  let payload =
    {|<?xml version="1.0" encoding="utf-8" ?>
<rss version="2.0">
  <channel>
    <item>
      <title>OpenAI &amp; ChatGPT</title>
      <link>https://openai.com/</link>
      <description>OpenAI&#39;s <b>latest</b> updates.</description>
    </item>
    <item>
      <title><![CDATA[Example Result]]></title>
      <link>https://example.com/hello?a=1&amp;b=2</link>
      <description><![CDATA[Snippet with <b>markup</b> &amp; detail]]></description>
    </item>
  </channel>
</rss>|}
  in
  let items = Tool_misc.parse_bing_rss_items payload in
  assert (List.length items = 2);
  match items with
  | (title1, url1, snippet1) :: (title2, url2, snippet2) :: _ ->
      assert (title1 = "OpenAI & ChatGPT");
      assert (url1 = "https://openai.com/");
      assert (snippet1 = "OpenAI's latest updates.");
      assert (title2 = "Example Result");
      assert (url2 = "https://example.com/hello?a=1&b=2");
      assert (snippet2 = "Snippet with markup & detail")
  | _ -> failwith "expected two parsed items"
)

let () = test "looks_like_rss_payload" (fun () ->
  assert (Tool_misc.looks_like_rss_payload "<rss><channel></channel></rss>");
  assert (Tool_misc.looks_like_rss_payload "<?xml version=\"1.0\"?><rss version=\"2.0\"></rss>");
  assert (not (Tool_misc.looks_like_rss_payload "<html><body>captcha</body></html>"))
)

let () = test "parse_bing_rss_items_drops_non_http_links" (fun () ->
  let payload =
    {|<rss><channel>
    <item><title>safe</title><link>https://example.com/</link><description>ok</description></item>
    <item><title>bad</title><link>javascript:alert(1)</link><description>bad</description></item>
    </channel></rss>|}
  in
  let items = Tool_misc.parse_bing_rss_items payload in
  assert (List.length items = 1);
  match items with
  | [ (title, url, _snippet) ] ->
      assert (title = "safe");
      assert (url = "https://example.com/")
  | _ -> failwith "expected one safe parsed item"
)

let () = test "parse_ddg_html" (fun () ->
  let payload =
    {|<html><body>
      <a rel="nofollow" class="result__a" href="/l/?uddg=https%3A%2F%2Fexample.com%2Falpha">Alpha <b>Result</b></a>
      <a class="result__snippet">Alpha <b>snippet</b></a>
      <a rel="nofollow" class="result__a" href="/l/?uddg=https%3A%2F%2Fexample.com%2Fbeta">Beta</a>
      <a class="result__snippet">Beta summary</a>
    </body></html>|}
  in
  let items = Tool_misc.parse_ddg_html payload in
  assert (List.length items = 2);
  match items with
  | (title1, url1, snippet1) :: (title2, url2, snippet2) :: _ ->
      assert (title1 = "Alpha Result");
      assert (url1 = "https://example.com/alpha");
      assert (snippet1 = "Alpha snippet");
      assert (title2 = "Beta");
      assert (url2 = "https://example.com/beta");
      assert (snippet2 = "Beta summary")
  | _ -> failwith "expected two parsed items"
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
                       = [ "searxng"; "duckduckgo"; "bing_rss" ]))))))))))
)

let () = test "web_search_provider_plan_reads_toml_boot_override" (fun () ->
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
                         = [ "searxng"; "duckduckgo"; "bing_rss" ])))))))))))
)

let () = test "web_search_provider_plan_defaults_to_scraping_fallbacks" (fun () ->
  with_env "MASC_SEARXNG_URL" None (fun () ->
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
                       = [ "duckduckgo"; "bing_rss" ]))))))))))
)

let () = test "web_search_provider_plan_prefers_configured_official_provider" (fun () ->
  with_env "MASC_SEARXNG_URL" None (fun () ->
    with_env "BRAVE_SEARCH_API_KEY" (Some "brave-key") (fun () ->
      with_env "TAVILY_API_KEY" None (fun () ->
        with_env "EXA_API_KEY" None (fun () ->
          with_env "BING_SEARCH_API_KEY" None (fun () ->
            with_env "AZURE_BING_SEARCH_API_KEY" None (fun () ->
              with_env "MASC_WEB_SEARCH_PROVIDER" (Some "brave") (fun () ->
                with_env "MASC_WEB_SEARCH_FALLBACKS" (Some "ddg,bing_rss") (fun () ->
                  with_env "MASC_WEB_SEARCH_PROVIDER_ORDER" None (fun () ->
                    assert
                      (Tool_misc.web_search_provider_plan ()
                       = [ "brave"; "duckduckgo"; "bing_rss" ]))))))))))
)

let () = test "web_search_simulate_for_test_falls_back_after_error" (fun () ->
  let result =
    Tool_misc.web_search_simulate_for_test ~query:"ocaml eio" ~limit:3
      [
        ("brave", `Error "provider failed");
        ("duckduckgo", `Hits [ ("Eio", "https://example.com/eio", "Fiber runtime") ]);
      ]
  in
  assert (Tool_result.is_success result);
  let json = parse_json ((Tool_result.message result)) in
  let result_json = Yojson.Safe.Util.member "result" json in
  assert (Yojson.Safe.Util.member "engine" result_json = `String "duckduckgo");
  assert (Yojson.Safe.Util.member "result_count" result_json = `Int 1)
)

let () = test "web_search_simulate_for_test_reports_all_failures" (fun () ->
  let result =
    Tool_misc.web_search_simulate_for_test ~query:"ocaml eio" ~limit:3
      [ ("brave", `Empty); ("bing_rss", `Error "rss unavailable") ]
  in
  assert (not (Tool_result.is_success result));
  assert (Tool_result.failure_class result = Some Tool_result.Runtime_failure);
  assert
    (str_contains (Tool_result.message result) "bing_rss: rss unavailable")
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
    </article>
  </body>
</html>|}
  in
  Tool_misc.with_web_search_simulation_for_test
    ~outcomes:[ ("duckduckgo", `Hits [ ("Result", url, "Snippet") ]) ]
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
              assert (hit |> member "page_content_status" |> to_string = "ok");
              assert (hit |> member "page_content_http_status" |> to_int = 200);
              assert (hit |> member "page_content_truncated" |> to_bool = false);
              assert
                (str_contains
                   (hit |> member "page_content" |> to_string)
                   "# Result Page");
              assert
                (str_contains
                   (hit |> member "page_content" |> to_string)
                   "Readable page content & proof.")
          | None -> failwith "dispatch returned None"))
)

let () = test "dispatch_web_search_include_content_keeps_result_on_fetch_error" (fun () ->
  let ctx = make_test_ctx () in
  let query = "include content fetch failure regression" in
  let url = "https://example.com/masc-web-search-fetch-failure" in
  Tool_misc.with_web_search_simulation_for_test
    ~outcomes:[ ("duckduckgo", `Hits [ ("Result", url, "Snippet") ]) ]
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
              assert (hit |> member "page_content_status" |> to_string = "error");
              assert
                (str_contains
                   (hit |> member "page_content" |> to_string)
                   "_Failed to retrieve page content:");
              assert
                (str_contains
                   (hit |> member "page_content" |> to_string)
                   ("Source: " ^ url))
          | None -> failwith "dispatch returned None"))
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

let test_persona_create_succeeds () =
  let personas_dir = Filename.temp_dir_name ^ "/masc_test_personas" in
  Unix.putenv "MASC_PERSONAS_DIR" personas_dir;
  let args =
    Tool_args.of_json
      (`Assoc
         [ ("persona_name", `String "test_persona")
         ; ("display_name", `String "Test Persona")
         ; ("role", `String "tester")
         ; ("instructions", `String "Be helpful.")
         ])
  in
  let result = Keeper_tool_persona_crud.handle_persona_create_json args in
  Alcotest.(check bool) "create succeeds" true (result = `Assoc [ ("success", `Bool true) ])

let test_persona_create_rejects_path_traversal () =
  let personas_dir = Filename.temp_dir_name ^ "/masc_test_personas" in
  Unix.putenv "MASC_PERSONAS_DIR" personas_dir;
  let args =
    Tool_args.of_json
      (`Assoc
         [ ("persona_name", `String "../evil")
         ; ("display_name", `String "Evil")
         ])
  in
  let result = Keeper_tool_persona_crud.handle_persona_create_json args in
  Alcotest.(check bool)
    "rejects path traversal"
    true
    (match result with `Assoc [ ("error", _) ] -> true | _ -> false)

let test_persona_update_succeeds () =
  let personas_dir = Filename.temp_dir_name ^ "/masc_test_personas" in
  Unix.putenv "MASC_PERSONAS_DIR" personas_dir;
  let create_args =
    Tool_args.of_json
      (`Assoc
         [ ("persona_name", `String "test_persona")
         ; ("display_name", `String "Test Persona")
         ; ("instructions", `String "Original.")
         ])
  in
  let _ = Keeper_tool_persona_crud.handle_persona_create_json create_args in
  let update_args =
    Tool_args.of_json
      (`Assoc
         [ ("persona_name", `String "test_persona")
         ; ("instructions", `String "Updated.")
         ])
  in
  let result = Keeper_tool_persona_crud.handle_persona_update_json update_args in
  Alcotest.(check bool) "update succeeds" true (result = `Assoc [ ("success", `Bool true) ])

let () =
  register "persona create succeeds" test_persona_create_succeeds;
  register "persona create rejects path traversal" test_persona_create_rejects_path_traversal;
  register "persona update succeeds" test_persona_update_succeeds

let () =
  Alcotest.run "Tool_misc"
    [
      ( "coverage",
        List.rev !test_cases
        |> List.map (fun (name, f) -> Alcotest.test_case name `Quick f) );
    ]

let () = exit 0
