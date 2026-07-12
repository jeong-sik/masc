(** Tests for Keeper_artifact_hydrator.

    Pins the contract:
    - The reducer hydrates only the LAST [keep_recent] Stored markers.
    - Older Stored markers stay in the message list as markers.
    - Inline blocks pass through.
    - Hydration miss (sha not in store) leaves the marker untouched —
      never raises, never empties the block.
    - Non-ToolResult blocks (Text, ToolUse, etc.) pass through. *)

module H = Masc.Keeper_artifact_hydrator
module B = Tool_blob_store
module O = Tool_output
module T = Agent_sdk.Types

let with_temp_dir f =
  let dir = Filename.temp_file "masc_hydrator_test" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let cleanup () =
    let rec rm path =
      if Sys.file_exists path then
        if Sys.is_directory path then begin
          Array.iter (fun n -> rm (Filename.concat path n)) (Sys.readdir path);
          Unix.rmdir path
        end
        else Unix.unlink path
    in
    try rm dir with _ -> ()
  in
  let r = try Ok (f dir) with e -> Error e in
  cleanup ();
  match r with Ok v -> v | Error e -> raise e

let store_a_blob store payload =
  match B.put_blocking store ~bytes:payload ~mime:"text/plain" with
  | O.Stored { sha256; bytes; preview; mime } ->
      let marker =
        O.encode_for_oas
          (O.Stored { sha256; bytes; preview; mime })
      in
      (sha256, marker)
  | O.Inline _ -> failwith "expected Stored"

let tool_result_block ~tool_use_id ~content : T.content_block =
  T.ToolResult
    {
      tool_use_id;
      content;
      outcome = T.Tool_succeeded;
      json = None;
      content_blocks = None;
    }

let make_tool_message ~tool_use_id ~content : T.message =
  {
    T.role = T.Tool;
    content = [ tool_result_block ~tool_use_id ~content ];
    name = None;
    tool_call_id = Some tool_use_id;
      metadata = [];
  }

let extract_tool_content (msg : T.message) : string =
  match msg.content with
  | [ T.ToolResult { content; _ } ] -> content
  | _ -> failwith "expected single ToolResult block"

let invoke_reducer reducer messages =
  match reducer.Agent_sdk.Context_reducer.strategy with
  | Agent_sdk.Context_reducer.Custom f -> f messages
  | _ -> failwith "expected Custom strategy"

(* --- Basic hydration --- *)

let test_hydrates_recent_marker () =
  with_temp_dir (fun dir ->
      let store = B.create ~base_path:dir in
      let payload = String.make 5000 'x' in
      let _sha, marker = store_a_blob store payload in
      let msg = make_tool_message ~tool_use_id:"t1" ~content:marker in
      let r = H.hydrate_recent ~store ~keep_recent:3 in
      let result = invoke_reducer r [ msg ] in
      Alcotest.(check int) "single message back" 1 (List.length result);
      Alcotest.(check string) "hydrated" payload
        (extract_tool_content (List.hd result)))

let test_hydration_preserves_tool_failure_provenance () =
  with_temp_dir (fun dir ->
      let store = B.create ~base_path:dir in
      let payload = String.make 5000 'x' in
      let _sha, marker = store_a_blob store payload in
      let msg : T.message =
        {
          T.role = T.Tool;
          content =
            [
              T.ToolResult
                {
                  tool_use_id = "failed-tool";
                  content = marker;
                  outcome =
                    T.Tool_failed
                      {
                        failure_kind = T.Validation_error;
                        error_class = Some T.Deterministic;
                      };
                  json = None;
                  content_blocks = None;
                };
            ];
          name = None;
          tool_call_id = Some "failed-tool";
          metadata = [];
        }
      in
      let result =
        invoke_reducer (H.hydrate_recent ~store ~keep_recent:1) [ msg ]
      in
      match (List.hd result).content with
      | [ T.ToolResult { content; outcome; _ } ] ->
          Alcotest.(check string) "hydrated payload" payload content;
          Alcotest.(check bool) "failure provenance preserved" true
            (outcome
             = T.Tool_failed
                 {
                   failure_kind = T.Validation_error;
                   error_class = Some T.Deterministic;
                 })
      | _ -> Alcotest.fail "expected one ToolResult block")

let test_keep_recent_zero_no_hydration () =
  with_temp_dir (fun dir ->
      let store = B.create ~base_path:dir in
      let _sha, marker = store_a_blob store "hello payload" in
      let msg = make_tool_message ~tool_use_id:"t1" ~content:marker in
      let r = H.hydrate_recent ~store ~keep_recent:0 in
      let result = invoke_reducer r [ msg ] in
      Alcotest.(check string) "marker unchanged" marker
        (extract_tool_content (List.hd result)))

let test_only_last_k_hydrated () =
  with_temp_dir (fun dir ->
      let store = B.create ~base_path:dir in
      let _sha1, m1 = store_a_blob store "first payload bytes" in
      let _sha2, m2 = store_a_blob store "second payload bytes" in
      let _sha3, m3 = store_a_blob store "third payload bytes" in
      let _sha4, m4 = store_a_blob store "fourth payload bytes" in
      let msgs =
        [
          make_tool_message ~tool_use_id:"t1" ~content:m1;
          make_tool_message ~tool_use_id:"t2" ~content:m2;
          make_tool_message ~tool_use_id:"t3" ~content:m3;
          make_tool_message ~tool_use_id:"t4" ~content:m4;
        ]
      in
      let r = H.hydrate_recent ~store ~keep_recent:2 in
      let result = invoke_reducer r msgs in
      Alcotest.(check int) "msg count preserved" 4 (List.length result);
      let contents = List.map extract_tool_content result in
      (match contents with
       | [ c1; c2; c3; c4 ] ->
           (* Last 2 should be hydrated, first 2 should keep markers. *)
           Alcotest.(check string) "first stays marker" m1 c1;
           Alcotest.(check string) "second stays marker" m2 c2;
           Alcotest.(check string) "third hydrated"
             "third payload bytes" c3;
           Alcotest.(check string) "fourth hydrated"
             "fourth payload bytes" c4
       | _ -> Alcotest.fail "expected 4 messages"))

(* --- Backward compat / passthrough --- *)

let test_inline_unchanged () =
  with_temp_dir (fun dir ->
      let store = B.create ~base_path:dir in
      let inline_payload = "small inline payload" in
      let msg = make_tool_message ~tool_use_id:"t1" ~content:inline_payload in
      let r = H.hydrate_recent ~store ~keep_recent:3 in
      let result = invoke_reducer r [ msg ] in
      Alcotest.(check string) "inline preserved" inline_payload
        (extract_tool_content (List.hd result)))

let test_non_tool_result_unchanged () =
  with_temp_dir (fun dir ->
      let store = B.create ~base_path:dir in
      let msg : T.message =
        {
          T.role = T.User;
          content = [ T.Text "hi" ];
          name = None;
          tool_call_id = None;
      metadata = [];
        }
      in
      let r = H.hydrate_recent ~store ~keep_recent:3 in
      let result = invoke_reducer r [ msg ] in
      Alcotest.(check int) "still one block" 1
        (List.length (List.hd result).content);
      match (List.hd result).content with
      | [ T.Text s ] -> Alcotest.(check string) "text" "hi" s
      | _ -> Alcotest.fail "expected Text")

(* --- Resilience: hydration miss leaves marker --- *)

let test_hydration_miss_keeps_marker () =
  with_temp_dir (fun dir ->
      let store = B.create ~base_path:dir in
      (* Construct a blob marker for content that was NEVER stored. *)
      let phantom =
        O.encode_for_oas
          (O.Stored
             {
               sha256 = String.make 64 'a';
               bytes = 9999;
               preview = "missing";
               mime = "text/plain";
             })
      in
      let msg = make_tool_message ~tool_use_id:"t1" ~content:phantom in
      let r = H.hydrate_recent ~store ~keep_recent:3 in
      let result = invoke_reducer r [ msg ] in
      Alcotest.(check string) "marker untouched" phantom
        (extract_tool_content (List.hd result)))

let test_keep_recent_from_env_default () =
  Unix.putenv "MASC_TOOL_HYDRATE_RECENT" "";
  Alcotest.(check int) "default applied"
    H.default_keep_recent (H.keep_recent_from_env ());
  Unix.putenv "MASC_TOOL_HYDRATE_RECENT" "5";
  Alcotest.(check int) "env override" 5 (H.keep_recent_from_env ());
  Unix.putenv "MASC_TOOL_HYDRATE_RECENT" "garbage";
  Alcotest.(check int) "garbage = default"
    H.default_keep_recent (H.keep_recent_from_env ());
  Unix.putenv "MASC_TOOL_HYDRATE_RECENT" ""

let () =
  Alcotest.run "keeper_artifact_hydrator"
    [
      ( "hydrate_recent",
        [
          Alcotest.test_case "single recent marker hydrated" `Quick
            test_hydrates_recent_marker;
          Alcotest.test_case "typed failure provenance preserved" `Quick
            test_hydration_preserves_tool_failure_provenance;
          Alcotest.test_case "keep_recent=0 = no hydration" `Quick
            test_keep_recent_zero_no_hydration;
          Alcotest.test_case "only last K hydrated" `Quick
            test_only_last_k_hydrated;
        ] );
      ( "passthrough",
        [
          Alcotest.test_case "inline unchanged" `Quick test_inline_unchanged;
          Alcotest.test_case "non-tool-result unchanged" `Quick
            test_non_tool_result_unchanged;
        ] );
      ( "resilience",
        [
          Alcotest.test_case "miss keeps marker" `Quick
            test_hydration_miss_keeps_marker;
        ] );
      ( "config",
        [
          Alcotest.test_case "keep_recent_from_env" `Quick
            test_keep_recent_from_env_default;
        ] );
    ]
