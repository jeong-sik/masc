(* RFC-0273 §3.4 — read-only verification of operator-supplied Settings
   resources. Covers the typed kind parse (unknown -> Error), the request body
   parse, the HTTP status classification (via the injected test hook, no real
   network), non-http scheme rejection, filesystem existence, and the JSON
   envelope. *)

open Server_dashboard_verify_resource

let member k json = Yojson.Safe.Util.member k json

let test_kind_of_string () =
  Alcotest.(check bool) "mcp_endpoint" true
    (match kind_of_string "mcp_endpoint" with Ok Mcp_endpoint -> true | _ -> false);
  Alcotest.(check bool) "gate_url" true
    (match kind_of_string "gate_url" with Ok Gate_url -> true | _ -> false);
  Alcotest.(check bool) "worktree_path" true
    (match kind_of_string "worktree_path" with Ok Worktree_path -> true | _ -> false);
  (* Unknown kind must be rejected, never coerced to a permissive default. *)
  Alcotest.(check bool) "unknown -> Error" true
    (match kind_of_string "runtime" with Error _ -> true | _ -> false);
  Alcotest.(check bool) "empty -> Error" true
    (match kind_of_string "" with Error _ -> true | _ -> false)

let test_parse_request () =
  (match parse_request {|{"kind":"mcp_endpoint","value":"https://x/mcp"}|} with
   | Ok (Mcp_endpoint, "https://x/mcp") -> ()
   | _ -> Alcotest.fail "valid body should parse to (Mcp_endpoint, value)");
  Alcotest.(check bool) "unknown kind -> Error" true
    (match parse_request {|{"kind":"nope","value":"x"}|} with Error _ -> true | _ -> false);
  Alcotest.(check bool) "missing value -> Error" true
    (match parse_request {|{"kind":"gate_url"}|} with Error _ -> true | _ -> false);
  Alcotest.(check bool) "non-string kind -> Error" true
    (match parse_request {|{"kind":1,"value":"x"}|} with Error _ -> true | _ -> false);
  Alcotest.(check bool) "malformed JSON -> Error" true
    (match parse_request "{not json" with Error _ -> true | _ -> false)

let probe_mcp () = verify ~kind:Mcp_endpoint ~value:"https://masc.local/mcp"

let with_status status f =
  set_http_get_for_tests (fun ~url:_ -> Ok status);
  let o = f () in
  clear_http_get_for_tests ();
  o

let test_http_classification () =
  let o200 = with_status 200 probe_mcp in
  Alcotest.(check bool) "200 ok" true o200.ok;
  Alcotest.(check (option int)) "200 http_status" (Some 200) o200.http_status;
  let o301 = with_status 301 probe_mcp in
  Alcotest.(check bool) "3xx reachable -> ok" true o301.ok;
  let o404 = with_status 404 probe_mcp in
  Alcotest.(check bool) "404 -> not ok" false o404.ok;
  Alcotest.(check (option int)) "404 http_status" (Some 404) o404.http_status;
  let o500 = with_status 500 probe_mcp in
  Alcotest.(check bool) "500 -> not ok" false o500.ok;
  (* connection-level failure is never reported as success *)
  set_http_get_for_tests (fun ~url:_ -> Error "connection refused");
  let oerr = probe_mcp () in
  clear_http_get_for_tests ();
  Alcotest.(check bool) "conn error -> not ok" false oerr.ok;
  Alcotest.(check (option int)) "conn error no http_status" None oerr.http_status

let test_http_rejects_non_http_scheme () =
  (* A non-http(s) scheme must be rejected before the server issues any GET. *)
  let called = ref false in
  set_http_get_for_tests (fun ~url:_ ->
    called := true;
    Ok 200);
  let o = verify ~kind:Gate_url ~value:"file:///etc/passwd" in
  clear_http_get_for_tests ();
  Alcotest.(check bool) "non-http rejected" false o.ok;
  Alcotest.(check bool) "hook NOT called for non-http scheme" false !called

let test_path_existence () =
  let cwd = Sys.getcwd () in
  Alcotest.(check bool) "existing dir -> ok" true (verify ~kind:Worktree_path ~value:cwd).ok;
  Alcotest.(check bool) "missing path -> not ok" false
    (verify ~kind:Worktree_path ~value:"/__masc_verify_nonexistent_xyz__").ok;
  (* "~" expands to $HOME, which exists on any host/CI runner. *)
  Alcotest.(check bool) "~ expands to existing HOME" true
    (verify ~kind:Worktree_path ~value:"~").ok

let test_to_json () =
  let o = verify ~kind:Worktree_path ~value:(Sys.getcwd ()) in
  let json = to_json ~kind:Worktree_path o in
  Alcotest.(check bool) "ok field" true (member "ok" json |> Yojson.Safe.Util.to_bool);
  Alcotest.(check string) "kind field" "worktree_path"
    (member "kind" json |> Yojson.Safe.Util.to_string);
  Alcotest.(check bool) "detail is a string" true
    (match member "detail" json with `String _ -> true | _ -> false);
  Alcotest.(check bool) "http_status null for path kind" true (member "http_status" json = `Null);
  (* HTTP kind carries the status as an int *)
  let oh = with_status 200 probe_mcp in
  let jh = to_json ~kind:Mcp_endpoint oh in
  Alcotest.(check int) "http_status int for http kind" 200
    (member "http_status" jh |> Yojson.Safe.Util.to_int)

let () =
  Alcotest.run "dashboard_verify_resource"
    [ ( "parse",
        [ Alcotest.test_case "kind_of_string rejects unknown" `Quick test_kind_of_string;
          Alcotest.test_case "parse_request" `Quick test_parse_request ] );
      ( "http",
        [ Alcotest.test_case "status classification" `Quick test_http_classification;
          Alcotest.test_case "rejects non-http scheme" `Quick test_http_rejects_non_http_scheme ] );
      ("path", [ Alcotest.test_case "filesystem existence" `Quick test_path_existence ]);
      ("json", [ Alcotest.test_case "to_json envelope" `Quick test_to_json ]) ]
