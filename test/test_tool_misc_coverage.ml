(** Coverage tests for Tool_misc *)

open Masc_mcp

let () = Random.self_init ()
let () = Mirage_crypto_rng_unix.use_default ()
let () = Server_startup_state.mark_state_ready ~backend_mode:"test"
let () =
  let base_path = Masc_test_deps.find_project_root () in
  ignore (Result.get_ok (Keeper_exec_tools.init_policy_config ~base_path))

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

let with_isolated_runtime_env f =
  with_env "MASC_BASE_PATH" None (fun () ->
    with_env "MASC_BASE_PATH_INPUT" None (fun () ->
      with_env "MASC_STORAGE_TYPE" None (fun () ->
        with_env "MASC_POSTGRES_URL" None (fun () ->
          with_env "DATABASE_URL" None (fun () ->
            with_env "SUPABASE_DB_URL" None (fun () ->
              with_env "SB_PG_URL" None f))))))

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
  let config = Coord.default_config tmp in
  let _ = Coord.init config ~agent_name:(Some "test-agent") in
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
  ignore (Coord.add_task ctx.config ~title:"default task" ~priority:2 ~description:"");
  Coord.ensure_room_bootstrap ctx.config;
  let second_room = ctx.config in
  ignore (Coord.add_task second_room ~title:"second task" ~priority:1 ~description:"");
  let args = `Assoc [] in
  match Tool_misc.dispatch ctx ~name:"masc_dashboard" ~args with
  | Some result ->
      assert result.success;
      assert (str_contains result.legacy_message "MASC Dashboard");
      assert (str_contains result.legacy_message "Namespace: default (flattened)");
      assert (not (str_contains result.legacy_message "second-room"));
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
      assert result.success;
      assert (str_contains result.legacy_message "MASC [");
      assert (str_contains result.legacy_message "ATTENTION:");
  | None -> failwith "dispatch returned None"
  | exception Effect.Unhandled _ ->
      Printf.printf "  (skipped: Eio runtime not available)\n"
)

let () = test "dispatch_dashboard_current_scope" (fun () ->
  let ctx = make_test_ctx () in
  Coord.ensure_room_bootstrap ctx.config;
  let focused = ctx.config in
  ignore (Coord.add_task focused ~title:"focus task" ~priority:2 ~description:"");
  let args = `Assoc [("scope", `String "current")] in
  match Tool_misc.dispatch ctx ~name:"masc_dashboard" ~args with
  | Some result ->
      assert result.success;
      assert (str_contains result.legacy_message "MASC Dashboard");
      assert (str_contains result.legacy_message "Namespace: default (flattened)");
      assert (not (str_contains result.legacy_message "focus-room"))
  | None -> failwith "dispatch returned None"
  | exception Effect.Unhandled _ ->
      Printf.printf "  (skipped: Eio runtime not available)\n"
)

let () = test "dispatch_dashboard_invalid_scope" (fun () ->
  let ctx = make_test_ctx () in
  let args = `Assoc [("scope", `String "everywhere")] in
  match Tool_misc.dispatch ctx ~name:"masc_dashboard" ~args with
  | Some result ->
      assert (not result.success);
      assert (str_contains result.legacy_message "Invalid dashboard scope")
  | None -> failwith "dispatch returned None"
)

(* Test dispatch gc — Eio context provided by test helper *)
let () = test "dispatch_gc" (fun () ->
  let ctx = make_test_ctx () in
  let args = `Assoc [("days", `Int 7)] in
  match Tool_misc.dispatch ctx ~name:"masc_gc" ~args with
  | Some result ->
      assert result.success;
      assert (String.length result.legacy_message > 0)
  | None -> failwith "dispatch returned None"
)

(* Test dispatch gc with default days *)
let () = test "dispatch_gc_default" (fun () ->
  let ctx = make_test_ctx () in
  let args = `Assoc [] in
  match Tool_misc.dispatch ctx ~name:"masc_gc" ~args with
  | Some result ->
      assert result.success;
      assert (String.length result.legacy_message > 0)
  | None -> failwith "dispatch returned None"
)

(* Test dispatch cleanup_zombies *)
let () = test "dispatch_cleanup_zombies" (fun () ->
  let ctx = make_test_ctx () in
  let args = `Assoc [] in
  match Tool_misc.dispatch ctx ~name:"masc_cleanup_zombies" ~args with
  | Some result ->
      assert result.success;
      assert (String.length result.legacy_message > 0)
  | None -> failwith "dispatch returned None"
)

let () = test "dispatch_web_search_requires_query" (fun () ->
  let ctx = make_test_ctx () in
  let args = `Assoc [] in
  match Tool_misc.dispatch ctx ~name:"masc_web_search" ~args with
  | Some result ->
      assert (not result.success);
      let json = parse_json result.legacy_message in
      assert (Yojson.Safe.Util.member "status" json = `String "error");
      assert (Yojson.Safe.Util.member "message" json = `String "query is required")
  | None -> failwith "dispatch returned None"
)

let () = test "dispatch_web_search_rejects_long_query" (fun () ->
  let ctx = make_test_ctx () in
  let query = String.make 501 'a' in
  let args = `Assoc [ ("query", `String query) ] in
  match Tool_misc.dispatch ctx ~name:"masc_web_search" ~args with
  | Some result ->
      assert (not result.success);
      let json = parse_json result.legacy_message in
      assert (Yojson.Safe.Util.member "status" json = `String "error");
      assert
        (Yojson.Safe.Util.member "message" json
         = `String "query must be at most 500 characters")
  | None -> failwith "dispatch returned None"
)

let () = test "dispatch_web_search_rejects_secret_like_query" (fun () ->
  let ctx = make_test_ctx () in
  let args = `Assoc [ ("query", `String "Authorization: Bearer secret-token") ] in
  match Tool_misc.dispatch ctx ~name:"masc_web_search" ~args with
  | Some result ->
      assert (not result.success);
      let json = parse_json result.legacy_message in
      assert (Yojson.Safe.Util.member "status" json = `String "error");
      assert
        (Yojson.Safe.Util.member "message" json
         = `String "query looks like it may contain secrets; refine it before using web search")
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
  assert result.success;
  let json = parse_json (Tool_result.message result) in
  let result_json = Yojson.Safe.Util.member "result" json in
  assert (Yojson.Safe.Util.member "engine" result_json = `String "duckduckgo");
  assert (Yojson.Safe.Util.member "result_count" result_json = `Int 1)
)

let () = test "web_search_simulate_for_test_reports_all_failures" (fun () ->
  let result =
    Tool_misc.web_search_simulate_for_test ~query:"ocaml eio" ~limit:3
      [ ("brave", `Empty); ("bing_rss", `Error "rss unavailable") ]
  in
  assert (not result.success);
  let json = parse_json (Tool_result.message result) in
  assert (Yojson.Safe.Util.member "status" json = `String "error");
  assert
    (str_contains
       Yojson.Safe.Util.(member "message" json |> to_string)
       "bing_rss: rss unavailable")
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

let () = test "dispatch_webrtc_offer" (fun () ->
  let ctx = make_test_ctx () in
  let args =
    `Assoc
      [
        ("agent_name", `String "offer-agent");
        ("ice_candidates", `List [ `String "candidate:127.0.0.1:5000" ]);
        ("dtls_fingerprint", `String "sha-256:AA:BB:CC");
      ]
  in
  match Tool_misc.dispatch ctx ~name:"masc_webrtc_offer" ~args with
  | Some result ->
      assert result.success;
      let json = parse_json result.legacy_message in
      let offer_id = Yojson.Safe.Util.(json |> member "offer_id" |> to_string) in
      assert (String.length offer_id > 0);
      ignore (Server_webrtc_transport.cleanup_expired_offers ~max_age_s:0.0 ())
  | None -> failwith "dispatch returned None"
)

let () = test "dispatch_webrtc_answer" (fun () ->
  let ctx = make_test_ctx () in
  let offer_args =
    `Assoc
      [
        ("agent_name", `String "offer-agent");
        ("ice_candidates", `List [ `String "candidate:127.0.0.1:5001" ]);
      ]
  in
  let offer_result =
    match Tool_misc.dispatch ctx ~name:"masc_webrtc_offer" ~args:offer_args with
    | Some result when result.success -> parse_json result.legacy_message
    | Some result -> failwith result.legacy_message
    | None -> failwith "offer dispatch returned None"
  in
  let offer_id =
    Yojson.Safe.Util.(offer_result |> member "offer_id" |> to_string)
  in
  let answer_args =
    `Assoc
      [
        ("offer_id", `String offer_id);
        ("agent_name", `String "answer-agent");
        ("ice_candidates", `List [ `String "candidate:127.0.0.1:5002" ]);
      ]
  in
  match Tool_misc.dispatch ctx ~name:"masc_webrtc_answer" ~args:answer_args with
  | Some result ->
      assert result.success;
      let json = parse_json result.legacy_message in
      let peer_id = Yojson.Safe.Util.(json |> member "peer_id" |> to_string) in
      assert (String.length peer_id > 0);
      Server_webrtc_transport.remove_peer peer_id
  | None -> failwith "dispatch returned None"
)

let () = test "dispatch_webrtc_offer_disabled" (fun () ->
  with_env "MASC_WEBRTC_ENABLED" (Some "0") (fun () ->
    let ctx = make_test_ctx () in
    let args =
      `Assoc
        [
          ("agent_name", `String "offer-agent");
          ("ice_candidates", `List [ `String "candidate:127.0.0.1:5000" ]);
        ]
    in
    match Tool_misc.dispatch ctx ~name:"masc_webrtc_offer" ~args with
    | Some result ->
        assert (not result.success);
        assert (str_contains result.legacy_message "webrtc transport disabled")
    | None -> failwith "dispatch returned None"))

let () = test "dispatch_webrtc_answer_disabled" (fun () ->
  with_env "MASC_WEBRTC_ENABLED" (Some "0") (fun () ->
    let ctx = make_test_ctx () in
    let args =
      `Assoc
        [
          ("offer_id", `String "offer-1");
          ("agent_name", `String "answer-agent");
          ("ice_candidates", `List [ `String "candidate:127.0.0.1:5002" ]);
        ]
    in
    match Tool_misc.dispatch ctx ~name:"masc_webrtc_answer" ~args with
    | Some result ->
        assert (not result.success);
        assert (str_contains result.legacy_message "webrtc transport disabled")
    | None -> failwith "dispatch returned None"))

let () = test "dispatch_tool_admin_snapshot" (fun () ->
  let ctx = make_test_ctx () in
  let args = `Assoc [] in
  match Tool_misc.dispatch ctx ~name:"masc_tool_admin_snapshot" ~args with
  | Some result ->
      assert result.success;
      let json = parse_json result.legacy_message in
      assert (Yojson.Safe.Util.member "tool_inventory" json <> `Null);
      assert (Yojson.Safe.Util.member "auth" json <> `Null);
      assert (Yojson.Safe.Util.member "http_auth_strict" (Yojson.Safe.Util.member "auth" json) <> `Null);
      assert (Yojson.Safe.Util.member "bind_host" (Yojson.Safe.Util.member "auth" json) <> `Null);
      assert (Yojson.Safe.Util.member "bind_is_loopback" (Yojson.Safe.Util.member "auth" json) <> `Null);
      assert (Yojson.Safe.Util.member "mode" json = `Null);
      (* keeper_policies removed with policy_mode purge *)
      assert (Yojson.Safe.Util.member "keeper_policies" json = `Null);
      assert (Yojson.Safe.Util.member "command_plane" json = `Null)
  | None -> failwith "dispatch returned None"
)

let () = test "dispatch_tool_admin_update_rejects_mode" (fun () ->
  let ctx = make_test_ctx () in
  let args =
    `Assoc
      [
        ("section", `String "mode");
        ("enabled_categories", `List [ `String "core"; `String "auth" ]);
      ]
  in
  match Tool_misc.dispatch ctx ~name:"masc_tool_admin_update" ~args with
  | Some result ->
      assert (not result.success)
  | None -> failwith "dispatch returned None"
)

let () = test "dispatch_tool_admin_update_auth" (fun () ->
  let ctx = make_test_ctx () in
  let args =
    `Assoc
      [
        ("section", `String "auth");
        ("enabled", `Bool true);
        ("require_token", `Bool true);
        ("token_expiry_hours", `Int 12);
      ]
  in
  match Tool_misc.dispatch ctx ~name:"masc_tool_admin_update" ~args with
  | Some result ->
      assert result.success;
      let json = parse_json result.legacy_message in
      assert (Yojson.Safe.Util.(json |> member "section" |> to_string) = "auth");
      let cfg = Auth.load_auth_config ctx.config.base_path in
      assert cfg.enabled;
      assert cfg.require_token;
      assert (cfg.token_expiry_hours = 12)
  | None -> failwith "dispatch returned None"
)

let () = test "dispatch_tool_admin_update_auth_rejects_removed_default_role" (fun () ->
  let ctx = make_test_ctx () in
  let before = Auth.load_auth_config ctx.config.base_path in
  let args =
    `Assoc
      [
        ("section", `String "auth");
        ("enabled", `Bool true);
        ("default_role", `String "reader");
      ]
  in
  match Tool_misc.dispatch ctx ~name:"masc_tool_admin_update" ~args with
  | Some result ->
      assert (not result.success);
      assert (str_contains result.legacy_message "default_role is no longer supported");
      let after = Auth.load_auth_config ctx.config.base_path in
      assert (after.enabled = before.enabled);
      assert (after.require_token = before.require_token);
      assert (after.token_expiry_hours = before.token_expiry_hours)
  | None -> failwith "dispatch returned None"
)

(* dispatch_tool_admin_update_unit_policy removed (CP purge: Command_plane_v2 deleted) *)

let () = test "dispatch_tool_admin_update_keeper_policy" (fun () ->
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio.Switch.run @@ fun sw ->
  let ctx = make_test_ctx () in
  let keeper_ctx : _ Tool_keeper.context =
    {
      config = ctx.config;
      agent_name = "tester";
      sw;
      clock = Eio.Stdenv.clock env;
      proc_mgr = Some (Eio.Stdenv.process_mgr env); net = None;
    }
  in
  Fun.protect
    ~finally:(fun () ->
      Keeper_keepalive.stop_keepalive "admin-keeper")
    (fun () ->
      match
        Tool_keeper.dispatch keeper_ctx ~name:"masc_keeper_up"
          ~args:
            (`Assoc
              [
                ("name", `String "admin-keeper");
                ("goal", `String "Admin tool policy test");
                ("proactive_enabled", `Bool false);
                ("autoboot_enabled", `Bool false);
              ])
      with
      | Some (true, _) -> (
          (* keeper_policy section removed with policy_mode purge —
             admin_update should reject the section *)
          let args =
            `Assoc
              [
                ("section", `String "keeper_policy");
                ("name", `String "admin-keeper");
              ]
          in
          match Tool_misc.dispatch ctx ~name:"masc_tool_admin_update" ~args with
          | Some inner when not inner.success -> () (* expected: section no longer supported *)
          | Some _ -> failwith "keeper_policy section should be rejected"
          | None -> failwith "dispatch returned None")
      | Some (false, err) -> failwith err
      | None -> failwith "keeper up dispatch returned None")
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

let () =
  Alcotest.run "Tool_misc"
    [
      ( "coverage",
        List.rev !test_cases
        |> List.map (fun (name, f) -> Alcotest.test_case name `Quick f) );
    ]

let () = exit 0
