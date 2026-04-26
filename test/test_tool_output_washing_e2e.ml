(** End-to-end integration test for the tool-output-washing series.

    Exercises the data flow across all the PRs in this series in one
    test, against real disk + real module boundaries:

      [Tool_blob_store.put]   <- PR 1 (foundation)
        \u2193 sha256 + sentinel marker
      [Tool_output.encode_for_oas]   <- PR 1 (encoder)
        \u2193 marker string
      [Agent_sdk.Types.ToolResult { content = marker }]
        \u2193 message list with marker
      [Keeper_artifact_hydrator.hydrate_recent]   <- PR 4 (reducer)
        \u2193 hydrated message list
      [Server_routes_http_routes_artifacts.blob_response]   <- PR 5 (endpoint)
        \u2193 JSON envelope with full content

    What this test buys: any cross-PR contract drift (sentinel format
    change in PR 1 not reflected in PR 4 decoder, or PR 5 returning a
    different envelope shape than the dashboard FE expects) shows up
    here as a single failure. *)

module B = Tool_blob_store
module O = Tool_output
module H = Masc_mcp.Keeper_artifact_hydrator
module A = Masc_mcp.Server_routes_http_routes_artifacts
module T = Agent_sdk.Types

let with_temp_base_path f =
  let dir = Filename.temp_file "masc_e2e_test" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let prev = Sys.getenv_opt "MASC_BASE_PATH" in
  Unix.putenv "MASC_BASE_PATH" dir;
  let restore () =
    match prev with
    | Some v -> Unix.putenv "MASC_BASE_PATH" v
    | None -> Unix.putenv "MASC_BASE_PATH" ""
  in
  let cleanup () =
    let rec rm path =
      if Sys.file_exists path
      then
        if Sys.is_directory path
        then (
          Array.iter (fun n -> rm (Filename.concat path n)) (Sys.readdir path);
          Unix.rmdir path)
        else Unix.unlink path
    in
    try rm dir with
    | _ -> ()
  in
  let r =
    try Ok (f dir) with
    | e -> Error e
  in
  restore ();
  cleanup ();
  match r with
  | Ok v -> v
  | Error e -> raise e
;;

let extract_tool_content (msg : T.message) : string =
  match msg.content with
  | [ T.ToolResult { content; _ } ] -> content
  | _ -> Alcotest.fail "expected single ToolResult block"
;;

(* --- The full data flow in one test --- *)

let test_full_flow_externalize_hydrate_serve () =
  with_temp_base_path (fun dir ->
    (* Step 1: Store a payload via the blob store directly (bypasses
         tool_bridge's one-shot Lazy singleton, but exercises the same
         module the bridge would use). *)
    let store = B.create ~base_path:dir in
    let payload = String.make 5_000 'x' in
    let stored_marker_value = B.put store ~bytes:payload ~mime:"text/plain" in
    (* Step 2: Verify the file landed in the sharded location. *)
    let sha256 =
      match stored_marker_value with
      | O.Stored { sha256; _ } -> sha256
      | O.Inline _ -> Alcotest.fail "put returned Inline"
    in
    let expected_path =
      Filename.concat
        dir
        (Filename.concat
           (Filename.concat ".masc/tool_blobs" (String.sub sha256 0 2))
           sha256)
    in
    Alcotest.(check bool) "blob file exists" true (Sys.file_exists expected_path);
    (* Step 3: Encode for OAS (sentinel marker string). *)
    let marker = O.encode_for_oas stored_marker_value in
    Alcotest.(check bool) "marker is sentinel" true (O.is_sentinel marker);
    (* Step 4: Marker round-trips through Tool_output.decode. *)
    (match O.decode_from_oas marker with
     | O.Stored { sha256 = decoded_sha; bytes; preview = _; mime } ->
       Alcotest.(check string) "decoded sha matches" sha256 decoded_sha;
       Alcotest.(check int) "decoded bytes" (String.length payload) bytes;
       Alcotest.(check string) "decoded mime" "text/plain" mime
     | O.Inline _ -> Alcotest.fail "decode lost the Stored variant");
    (* Step 5: Build a message list with the marker as a ToolResult.
         The hydrator should re-inflate it because keep_recent >= 1. *)
    let msg : T.message =
      { T.role = T.Tool
      ; content =
          [ T.ToolResult
              { tool_use_id = "tool_call_42"
              ; content = marker
              ; is_error = false
              ; json = None
              }
          ]
      ; name = None
      ; tool_call_id = Some "tool_call_42"
      ; metadata = []
      }
    in
    let reducer = H.hydrate_recent ~store ~keep_recent:3 in
    let hydrated_msgs =
      match reducer.Agent_sdk.Context_reducer.strategy with
      | Agent_sdk.Context_reducer.Custom f -> f [ msg ]
      | _ -> Alcotest.fail "expected Custom strategy"
    in
    Alcotest.(check string)
      "hydrated content matches original payload"
      payload
      (extract_tool_content (List.hd hydrated_msgs));
    (* Step 6: The HTTP endpoint helper returns the same bytes. The
         endpoint reads MASC_BASE_PATH, so it sees the same store our
         bridge wrote into. This catches base-path drift between
         producer and consumer. *)
    let json, status = A.blob_response ~sha256 in
    Alcotest.(check bool) "endpoint returns 200" true (status = `OK);
    let envelope_content = Yojson.Safe.Util.(json |> member "content" |> to_string) in
    Alcotest.(check string) "endpoint payload matches" payload envelope_content;
    let envelope_bytes = Yojson.Safe.Util.(json |> member "bytes" |> to_int) in
    Alcotest.(check int) "endpoint bytes count" (String.length payload) envelope_bytes;
    let envelope_sha = Yojson.Safe.Util.(json |> member "sha256" |> to_string) in
    Alcotest.(check string) "endpoint sha matches" sha256 envelope_sha)
;;

(* --- Older messages keep markers (recency budget enforced cumulatively) --- *)

let test_recency_budget_holds_across_modules () =
  with_temp_base_path (fun dir ->
    let store = B.create ~base_path:dir in
    let stored payload =
      let v = B.put store ~bytes:payload ~mime:"text/plain" in
      O.encode_for_oas v
    in
    let m1 = stored "ancient one" in
    let m2 = stored "older one" in
    let m3 = stored "recent one" in
    let m4 = stored "newest one" in
    let make_msg ~id content : T.message =
      { T.role = T.Tool
      ; content =
          [ T.ToolResult { tool_use_id = id; content; is_error = false; json = None } ]
      ; name = None
      ; tool_call_id = Some id
      ; metadata = []
      }
    in
    let msgs =
      [ make_msg ~id:"t1" m1
      ; make_msg ~id:"t2" m2
      ; make_msg ~id:"t3" m3
      ; make_msg ~id:"t4" m4
      ]
    in
    let reducer = H.hydrate_recent ~store ~keep_recent:2 in
    let result =
      match reducer.Agent_sdk.Context_reducer.strategy with
      | Agent_sdk.Context_reducer.Custom f -> f msgs
      | _ -> Alcotest.fail "expected Custom strategy"
    in
    let contents = List.map extract_tool_content result in
    match contents with
    | [ c1; c2; c3; c4 ] ->
      (* First two stayed as markers; last two got hydrated. *)
      Alcotest.(check bool) "ancient stays marker" true (O.is_sentinel c1);
      Alcotest.(check bool) "older stays marker" true (O.is_sentinel c2);
      Alcotest.(check string) "recent hydrated" "recent one" c3;
      Alcotest.(check string) "newest hydrated" "newest one" c4
    | _ -> Alcotest.fail "expected 4 messages")
;;

(* --- Endpoint validation rejects bad shas --- *)

let test_endpoint_rejects_invalid_sha () =
  Alcotest.(check bool) "exact 64 hex" true (A.is_valid_sha256 (String.make 64 'a'));
  Alcotest.(check bool) "63 chars" false (A.is_valid_sha256 (String.make 63 'a'));
  Alcotest.(check bool) "non-hex" false (A.is_valid_sha256 ("g" ^ String.make 63 'a'));
  Alcotest.(check bool)
    "path-traversal attempt"
    false
    (A.is_valid_sha256 "../../etc/passwd")
;;

let () =
  Alcotest.run
    "tool_output_washing_e2e"
    [ ( "full data flow"
      , [ Alcotest.test_case
            "externalize -> hydrate -> serve"
            `Quick
            test_full_flow_externalize_hydrate_serve
        ; Alcotest.test_case
            "recency budget across modules"
            `Quick
            test_recency_budget_holds_across_modules
        ] )
    ; ( "endpoint hardening"
      , [ Alcotest.test_case
            "rejects invalid sha shapes"
            `Quick
            test_endpoint_rejects_invalid_sha
        ] )
    ]
;;
