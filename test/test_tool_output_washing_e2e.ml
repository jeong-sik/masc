(** End-to-end integration test for stored Keeper tool output.

    Exercises the production data flow against real disk and module
    boundaries:

      [Tool_bridge.maybe_externalize]
        \u2193 sha256 + blob marker
      [Agent_core.Types.ToolResult { content = marker }]
        \u2193 provider-bound message keeps marker
      [Keeper_artifact_read.handle]
        \u2193 one bounded typed page
      [Server_routes_http_routes_artifacts.blob_response]
        \u2193 JSON envelope with full content

    Marker projection, explicit model retrieval, and dashboard retrieval must
    all resolve the same Workspace base path without putting full bytes back
    into later provider requests. *)

module O = Tool_output
module A = Server_routes_http_routes_artifacts
module Bridge = Masc.Tool_bridge
module K = Masc.Keeper_run_tools_hooks
module R = Masc.Keeper_artifact_read
module E = Masc.Keeper_tool_execution
module T = Agent_core.Types

let project_completed_exn ?model_projection ~base_path ~tool_name data =
  let result =
    Tool_result.make_ok ~tool_name ~start_time:0.0 ~data ()
  in
  match Bridge.to_agent_core_typed_result ?model_projection ~base_path result with
  | Ok { content; _ } -> content
  | Error { message; _ } -> Alcotest.fail message

let with_temp_base_path f =
  let dir = Filename.temp_file "masc_e2e_test" "" in
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

let extract_tool_content (msg : T.message) : string =
  match msg.content with
  | [ T.ToolResult { content; _ } ] -> content
  | _ -> Alcotest.fail "expected single ToolResult block"

let test_artifact_page_makes_progress () =
  let request offset max_bytes =
    match
      R.For_testing.request_of_json
        (`Assoc
           [ "sha256", `String (String.make 64 'a')
           ; "offset", `Int offset
           ; "max_bytes", `Int max_bytes
           ])
    with
    | Ok request -> request
    | Error error -> Alcotest.fail (R.invalid_request_to_string error)
  in
  let emoji = "\240\159\152\128x" in
  let incident_sized_payload = String.make 2_500 'w' in
  let default_request =
    match
      R.For_testing.request_of_json
        (`Assoc [ "sha256", `String (String.make 64 'a') ])
    with
    | Ok request -> request
    | Error error -> Alcotest.fail (R.invalid_request_to_string error)
  in
  let incident_page =
    match R.For_testing.page default_request incident_sized_payload with
    | Ok page -> page
    | Error error -> Alcotest.fail error
  in
  Alcotest.(check int)
    "2.5KB artifact completes in one default page"
    (String.length incident_sized_payload)
    incident_page.next_offset;
  Alcotest.(check bool) "2.5KB default page reaches EOF" true incident_page.eof;
  let utf8_page =
    match R.For_testing.page (request 0 4) emoji with
    | Ok page -> page
    | Error error -> Alcotest.fail error
  in
  Alcotest.(check int) "UTF-8 page advances by one codepoint"
    4 utf8_page.next_offset;
  (match utf8_page.encoding with
   | R.Utf_8 -> ()
   | R.Base64 -> Alcotest.fail "valid UTF-8 page was encoded as base64");
  Alcotest.(check string) "UTF-8 content"
    "\240\159\152\128" utf8_page.content;
  let binary_page =
    match R.For_testing.page (request 1 1) emoji with
    | Ok page -> page
    | Error error -> Alcotest.fail error
  in
  Alcotest.(check int) "mid-codepoint byte still advances"
    2 binary_page.next_offset;
  (match binary_page.encoding with
   | R.Base64 -> ()
   | R.Utf_8 -> Alcotest.fail "invalid UTF-8 byte was returned as text");
  Alcotest.(check string) "binary page preserves exact byte"
    (Base64.encode_string "\159")
    binary_page.content;
  let invalid_byte_page =
    match R.For_testing.page (request 0 1) "\128" with
    | Ok page -> page
    | Error error -> Alcotest.fail error
  in
  Alcotest.(check int) "arbitrary byte makes monotonic progress"
    1 invalid_byte_page.next_offset

(* --- The full data flow in one test --- *)

let test_full_flow_externalize_reference_serve () =
  with_temp_base_path (fun dir ->
      (* Step 1: Externalize through the production MASC -> AGENT_CORE bridge with
         the same explicit Workspace base path the reader receives. The byte
         count reproduces the exact executor artifact that expanded an 88 KB
         checkpoint into a 9 MB provider request. *)
      let payload = String.make 8_922_079 'x' in
      let marker =
        project_completed_exn
          ~base_path:dir
          ~tool_name:"Execute"
          (`String payload)
      in

      (* Step 2: Verify the file landed in the sharded location. *)
      let sha256 =
        match O.decode_from_agent_core marker with
        | O.Decoded { sha256; _ } -> sha256
        | O.Not_marker -> Alcotest.fail "bridge did not externalize payload"
        | O.Invalid_marker { detail } ->
          Alcotest.failf "bridge returned invalid marker: %s" detail
      in
      let expected_path =
        Filename.concat dir
          (Filename.concat (Filename.concat ".masc/tool_blobs" (String.sub sha256 0 2)) sha256)
      in
      Alcotest.(check bool) "blob file exists" true
        (Sys.file_exists expected_path);

      (* Step 3: The bridge returned an exact AGENT_CORE marker. *)
      Alcotest.(check bool) "blob marker recognized" true (O.is_marker marker);

      (* Step 4: Marker round-trips through Tool_output.decode. *)
      (match O.decode_from_agent_core marker with
       | O.Decoded { sha256 = decoded_sha; bytes; preview = _; mime } ->
           Alcotest.(check string) "decoded sha matches" sha256 decoded_sha;
           Alcotest.(check int) "decoded bytes" (String.length payload) bytes;
           Alcotest.(check string) "decoded mime" "text/plain" mime
       | O.Not_marker -> Alcotest.fail "decode lost the marker"
       | O.Invalid_marker { detail } ->
           Alcotest.failf "decode reported Invalid_marker: %s" detail);

      (* Step 5: The provider-bound ToolResult keeps the marker. Full bytes
         must not be re-inflated into every later model request. *)
      let msg : T.message =
        {
          T.role = T.Tool;
          content =
            [
              T.ToolResult
                {
                  tool_use_id = "tool_call_42";
                  content = marker;
                  outcome = T.Tool_succeeded;
                  json = None;
                  content_blocks = None;
                };
            ];
          name = None;
          tool_call_id = Some "tool_call_42";
      metadata = [];
        }
      in
      let projected =
        match
          K.project_model_input
            ~base_path:dir
            ~gate_replay_evidence:None
            [ msg ]
        with
        | Ok messages -> messages
        | Error error ->
          Alcotest.failf
            "provider projection failed: %s"
            (Agent_core.Error.to_string error)
      in
      let projected_content = extract_tool_content (List.hd projected) in
      Alcotest.(check string) "provider content keeps artifact reference"
        marker projected_content;
      Alcotest.(check bool) "provider content excludes stored payload"
        false
        (String.equal payload projected_content);

      (* Step 6: The model-visible read tool resolves only the explicit
         requested page. Its descriptor-owned bounded-inline projection cannot
         turn it into a nested artifact reference. *)
      let read_result =
        R.handle
          ~base_path:dir
          ~args:
            (`Assoc
               [ "sha256", `String sha256
               ; "offset", `Int 1_000
               ; "max_bytes", `Int 128
               ])
      in
      (match read_result.E.disposition with
       | Tool_result.Completed () -> ()
       | Tool_result.Deferred () | Tool_result.Failed _ ->
         Alcotest.fail "explicit artifact read did not complete");
      let read_output =
        project_completed_exn
          ~model_projection:Tool_output.bounded_inline_model_projection
          ~base_path:dir
          ~tool_name:"keeper_artifact_read"
          (Option.value
             ~default:(`String read_result.raw_output)
             read_result.data)
      in
      Alcotest.(check string) "bounded page remains inline"
        read_result.raw_output read_output;
      Alcotest.(check bool) "bounded page is not a marker"
        false (O.is_marker read_output);
      let read_json = Yojson.Safe.from_string read_output in
      Alcotest.(check int) "page offset"
        1_000
        Yojson.Safe.Util.(read_json |> member "offset" |> to_int);
      Alcotest.(check int) "page next offset"
        1_128
        Yojson.Safe.Util.(read_json |> member "next_offset" |> to_int);
      Alcotest.(check string) "page encoding"
        "utf-8"
        Yojson.Safe.Util.(read_json |> member "encoding" |> to_string);
      Alcotest.(check string) "page content"
        (String.make 128 'x')
        Yojson.Safe.Util.(read_json |> member "content" |> to_string);
      let tail_offset = String.length payload - 64 in
      let tail_result =
        R.handle
          ~base_path:dir
          ~args:
            (`Assoc
               [ "sha256", `String sha256
               ; "offset", `Int tail_offset
               ; "max_bytes", `Int 128
               ])
      in
      let tail_json = Yojson.Safe.from_string tail_result.raw_output in
      Alcotest.(check int) "tail page starts at requested offset"
        tail_offset
        Yojson.Safe.Util.(tail_json |> member "offset" |> to_int);
      Alcotest.(check int) "tail page stops at total bytes"
        (String.length payload)
        Yojson.Safe.Util.(tail_json |> member "next_offset" |> to_int);
      Alcotest.(check bool) "tail page reaches EOF"
        true
        Yojson.Safe.Util.(tail_json |> member "eof" |> to_bool);
      Alcotest.(check string) "tail page returns only remaining bytes"
        (String.make 64 'x')
        Yojson.Safe.Util.(tail_json |> member "content" |> to_string);

      (* A sha256 is the same content address used by the HTTP route; the model
         tool deliberately adds no run-local claim or Gate because it is
         already scoped to the Keeper's explicit Workspace base path. HTTP
         strict mode independently retains its read-auth boundary. *)
      let second_marker =
        project_completed_exn
          ~base_path:dir
          ~tool_name:"Execute"
          (`String
            (String.make
               (Bridge.default_externalize_threshold_bytes + 1)
               'z'))
      in
      let second_sha =
        match O.decode_from_agent_core second_marker with
        | O.Decoded { sha256; _ } -> sha256
        | O.Not_marker | O.Invalid_marker _ ->
          Alcotest.fail "second artifact setup failed"
      in
      let second_read =
        R.handle
          ~base_path:dir
          ~args:(`Assoc [ "sha256", `String second_sha; "max_bytes", `Int 1 ])
      in
      (match second_read.E.disposition with
       | Tool_result.Completed () -> ()
       | Tool_result.Failed _ | Tool_result.Deferred () ->
         Alcotest.fail "public-read artifact capability was rejected");

      (* Step 7: The HTTP endpoint helper receives the same explicit Workspace
         base path as the producer and returns the same bytes. *)
      let json, status = A.blob_response ~base_path:dir ~sha256 in
      Alcotest.(check bool) "endpoint returns 200" true (status = `OK);
      let envelope_content =
        Yojson.Safe.Util.(json |> member "content" |> to_string)
      in
      Alcotest.(check string) "endpoint payload matches"
        payload envelope_content;
      let envelope_bytes =
        Yojson.Safe.Util.(json |> member "bytes" |> to_int)
      in
      Alcotest.(check int) "endpoint bytes count"
        (String.length payload) envelope_bytes;
      let envelope_sha =
        Yojson.Safe.Util.(json |> member "sha256" |> to_string)
      in
      Alcotest.(check string) "endpoint sha matches" sha256 envelope_sha)

(* --- Endpoint validation rejects bad shas --- *)

let test_endpoint_rejects_invalid_sha () =
  Alcotest.(check bool) "exact 64 hex" true
    (A.is_valid_sha256 (String.make 64 'a'));
  Alcotest.(check bool) "63 chars" false
    (A.is_valid_sha256 (String.make 63 'a'));
  Alcotest.(check bool) "non-hex" false
    (A.is_valid_sha256
       ("g" ^ String.make 63 'a'));
  Alcotest.(check bool) "path-traversal attempt" false
    (A.is_valid_sha256 "../../etc/passwd")

let () =
  Alcotest.run "tool_output_washing_e2e"
    [
      ( "full data flow",
        [
          Alcotest.test_case "externalize -> reference -> serve" `Quick
            test_full_flow_externalize_reference_serve;
        ] );
      ( "endpoint hardening",
        [
          Alcotest.test_case "rejects invalid sha shapes" `Quick
            test_endpoint_rejects_invalid_sha;
        ] );
      ( "range contract",
        [
          Alcotest.test_case "artifact pages make progress" `Quick
            test_artifact_page_makes_progress;
        ] );
    ]
