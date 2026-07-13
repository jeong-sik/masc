(** Tests for [Tool_bridge.maybe_externalize].

    Pins the threshold contract:
    - small payloads (< threshold) flow through verbatim
    - large payloads (> threshold) are stored and replaced with
      [Tool_output.Stored] blob marker
    - boundary cases (exactly == threshold) follow [<=] semantics
    - externalization is skipped when [MASC_BASE_PATH] is unset or when
      [MASC_TOOL_EXTERNALIZE=0] is set
    - a blob-store failure preserves the original bytes
    - tool identity and free-form error JSON never change bridge behavior

    The actual blob store is exercised in [test_tool_blob_store]; here we
    only verify the bridge's wiring decisions. *)

module B = Masc.Tool_bridge
module O = Tool_output

let tool_ok ?(tool_name = "") message =
  Tool_result.make_ok ~tool_name ~start_time:0.0 ~data:(`String message) ()
;;

let tool_error ?(tool_name = "") message =
  Tool_result.make_err
    ~tool_name
    ~class_:Tool_result.Runtime_failure
    ~start_time:0.0
    ~data:(`String message)
    message
;;

let with_temp_base_path f =
  let dir = Filename.temp_file "masc_bridge_test" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let prev_base = Sys.getenv_opt "MASC_BASE_PATH" in
  let prev_base_input = Sys.getenv_opt "MASC_BASE_PATH_INPUT" in
  let prev_disable = Sys.getenv_opt "MASC_TOOL_EXTERNALIZE" in
  let prev_threshold = Sys.getenv_opt "MASC_TOOL_EXTERNALIZE_THRESHOLD_BYTES" in
  Unix.putenv "MASC_BASE_PATH" dir;
  Unix.putenv "MASC_BASE_PATH_INPUT" dir;
  Unix.putenv "MASC_TOOL_EXTERNALIZE" "1";
  let restore () =
    (match prev_base with
     | Some v -> Unix.putenv "MASC_BASE_PATH" v
     | None -> Unix.putenv "MASC_BASE_PATH" "");
    (match prev_base_input with
     | Some v -> Unix.putenv "MASC_BASE_PATH_INPUT" v
     | None -> Unix.putenv "MASC_BASE_PATH_INPUT" "");
    (match prev_disable with
     | Some v -> Unix.putenv "MASC_TOOL_EXTERNALIZE" v
     | None -> Unix.putenv "MASC_TOOL_EXTERNALIZE" "");
    match prev_threshold with
    | Some v -> Unix.putenv "MASC_TOOL_EXTERNALIZE_THRESHOLD_BYTES" v
    | None -> Unix.putenv "MASC_TOOL_EXTERNALIZE_THRESHOLD_BYTES" ""
  in
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
  restore ();
  cleanup ();
  match r with Ok v -> v | Error e -> raise e

let test_threshold_default_under () =
  Unix.putenv "MASC_BASE_PATH" "";
  Unix.putenv "MASC_BASE_PATH_INPUT" "";
  Unix.putenv "MASC_TOOL_EXTERNALIZE" "1";
  let small = "short payload" in
  let result = B.maybe_externalize small in
  Alcotest.(check string) "small unchanged" small result;
  let large = String.make 8192 'x' in
  let result_large = B.maybe_externalize large in
  Alcotest.(check string) "large unchanged when no base path" large result_large

let test_disabled_passthrough () =
  Unix.putenv "MASC_TOOL_EXTERNALIZE" "0";
  let large = String.make 8192 'y' in
  let result = B.maybe_externalize large in
  Alcotest.(check string) "disabled = passthrough" large result;
  Unix.putenv "MASC_TOOL_EXTERNALIZE" ""

let test_threshold_env_override () =
  Unix.putenv "MASC_TOOL_EXTERNALIZE_THRESHOLD_BYTES" "100";
  Unix.putenv "MASC_TOOL_EXTERNALIZE" "1";
  Alcotest.(check int) "threshold 100" 100 (B.externalize_threshold_bytes ());
  Unix.putenv "MASC_TOOL_EXTERNALIZE_THRESHOLD_BYTES" "garbage";
  Alcotest.(check int) "garbage falls back to default"
    B.default_externalize_threshold_bytes
    (B.externalize_threshold_bytes ());
  Unix.putenv "MASC_TOOL_EXTERNALIZE_THRESHOLD_BYTES" ""

(* --- Round-trip via to_oas_typed_result on small payloads --- *)

let test_to_oas_typed_small_inlined () =
  Unix.putenv "MASC_TOOL_EXTERNALIZE" "0";
  let small = "small ok" in
  match B.to_oas_typed_result (tool_ok ~tool_name:"test" small) with
  | Ok { content; _ } ->
      Alcotest.(check string) "inlined verbatim" small content;
      Alcotest.(check bool) "no marker" false (O.is_marker content)
  | Error _ -> Alcotest.fail "expected Ok"

let test_tool_identity_does_not_bypass_externalization () =
  with_temp_base_path (fun _dir ->
    Unix.putenv "MASC_TOOL_EXTERNALIZE_THRESHOLD_BYTES" "100";
    let payload = String.make 5_000 'b' in
    let check_tool tool_name =
      match B.to_oas_typed_result (tool_ok ~tool_name payload) with
      | Ok { content; _ } ->
        Alcotest.(check bool) "externalized" true (O.is_marker content)
      | Error _ -> Alcotest.fail "expected Ok"
    in
    check_tool "opaque_tool_a";
    check_tool "opaque_tool_b";
    Unix.putenv "MASC_TOOL_EXTERNALIZE_THRESHOLD_BYTES" "")

let test_to_oas_typed_error_inlined () =
  Unix.putenv "MASC_TOOL_EXTERNALIZE" "0";
  match B.to_oas_typed_result (tool_error ~tool_name:"test" "fail") with
  | Ok _ -> Alcotest.fail "expected Error"
  | Error { message; recoverable; _ } ->
      Alcotest.(check string) "message" "fail" message;
      Alcotest.(check bool) "default recoverable=false" false recoverable

let test_to_oas_typed_error_ignores_json_metadata () =
  Unix.putenv "MASC_TOOL_EXTERNALIZE" "0";
  let msg =
    {|{"ok":false,"error":"try again","recoverable":true,"error_class":"transient_mutex_contention"}|}
  in
  let tr : Tool_result.result =
    Error
      { Tool_result.class_ = Tool_result.Runtime_failure
      ; message = msg
      ; data = Yojson.Safe.from_string msg
      ; tool_name = "test"
      ; duration_ms = 0.0
      }
  in
  match B.to_oas_typed_result tr with
  | Ok _ -> Alcotest.fail "expected Error"
  | Error { message; recoverable; error_class } ->
      Alcotest.(check string) "message" msg message;
      Alcotest.(check bool) "runtime failure stays non-recoverable" false recoverable;
      (match error_class with
       | Some Agent_sdk.Types.Unknown -> ()
       | _ -> Alcotest.fail "expected typed runtime failure mapping")

let test_to_oas_typed_result_preserves_workflow_rejection () =
  Unix.putenv "MASC_TOOL_EXTERNALIZE" "0";
  let tr =
    Tool_result.error
      ~failure_class:(Some Tool_result.Workflow_rejection)
      ~tool_name:"masc_transition"
      ~start_time:0.0
      "Invalid task state: submit_for_verification requires verification evidence"
  in
  match B.to_oas_typed_result tr with
  | Ok _ -> Alcotest.fail "expected Error"
  | Error { recoverable; error_class; _ } ->
    Alcotest.(check bool) "workflow rejection is non-recoverable" false recoverable;
    (match error_class with
     | Some Agent_sdk.Types.Deterministic -> ()
     | _ -> Alcotest.fail "expected deterministic error_class")

let test_to_oas_typed_result_preserves_transient_failure_class () =
  Unix.putenv "MASC_TOOL_EXTERNALIZE" "0";
  let tr =
    Tool_result.error
      ~failure_class:(Some Tool_result.Transient_error)
      ~tool_name:"tool_search_files"
      ~start_time:0.0
      {|{"ok":false,"error":"mutex contention","failure_class":"transient_error","recoverable":true,"error_class":"transient_mutex_contention"}|}
  in
  match B.to_oas_typed_result tr with
  | Ok _ -> Alcotest.fail "expected Error"
  | Error { recoverable; error_class; _ } ->
    Alcotest.(check bool) "transient remains recoverable" true recoverable;
    (match error_class with
     | Some Agent_sdk.Types.Transient -> ()
     | _ -> Alcotest.fail "expected transient error_class")

let test_round_trip_through_oas () =
  Unix.putenv "MASC_TOOL_EXTERNALIZE" "0";
  let payload = String.make 5000 'p' in
  match B.to_oas_typed_result (tool_ok ~tool_name:"test" payload) with
  | Ok { content; _ } ->
      let decoded = O.decode_from_oas content in
      (match decoded with
       | O.Inline s -> Alcotest.(check string) "inline preserved" payload s
       | O.Stored _ ->
           Alcotest.fail "did not expect Stored when externalize=0")
  | Error _ -> Alcotest.fail "expected Ok"

(* --- Marker encoding round-trip via the bridge --- *)

let test_externalize_with_temp_base_path () =
  with_temp_base_path (fun _dir ->
      Unix.putenv "MASC_TOOL_EXTERNALIZE" "1";
      let payload = String.make 4096 'z' in
      let result = B.maybe_externalize payload in
      Alcotest.(check bool) "encoded as marker" true (O.is_marker result);
      match O.decode_from_oas result with
      | O.Stored { sha256; bytes; _ } ->
        Alcotest.(check int) "byte count" (String.length payload) bytes;
        Alcotest.(check int) "sha length" 64 (String.length sha256)
      | O.Inline _ -> Alcotest.fail "expected Stored after externalize")

let test_blob_store_failure_preserves_original_bytes () =
  let path = Filename.temp_file "masc_bridge_not_a_directory" "" in
  let prev_base = Sys.getenv_opt "MASC_BASE_PATH" in
  let prev_base_input = Sys.getenv_opt "MASC_BASE_PATH_INPUT" in
  let prev_disable = Sys.getenv_opt "MASC_TOOL_EXTERNALIZE" in
  let prev_threshold = Sys.getenv_opt "MASC_TOOL_EXTERNALIZE_THRESHOLD_BYTES" in
  let restore () =
    (match prev_base with
     | Some value -> Unix.putenv "MASC_BASE_PATH" value
     | None -> Unix.putenv "MASC_BASE_PATH" "");
    (match prev_base_input with
     | Some value -> Unix.putenv "MASC_BASE_PATH_INPUT" value
     | None -> Unix.putenv "MASC_BASE_PATH_INPUT" "");
    (match prev_disable with
     | Some value -> Unix.putenv "MASC_TOOL_EXTERNALIZE" value
     | None -> Unix.putenv "MASC_TOOL_EXTERNALIZE" "");
    (match prev_threshold with
     | Some value -> Unix.putenv "MASC_TOOL_EXTERNALIZE_THRESHOLD_BYTES" value
     | None -> Unix.putenv "MASC_TOOL_EXTERNALIZE_THRESHOLD_BYTES" "");
    Sys.remove path
  in
  Fun.protect
    ~finally:restore
    (fun () ->
      Unix.putenv "MASC_BASE_PATH" path;
      Unix.putenv "MASC_BASE_PATH_INPUT" path;
      Unix.putenv "MASC_TOOL_EXTERNALIZE" "1";
      Unix.putenv "MASC_TOOL_EXTERNALIZE_THRESHOLD_BYTES" "1";
      let payload = "\000exact\nbytes\255" in
      Alcotest.(check string)
        "failed store returns original bytes"
        payload
        (B.maybe_externalize payload))

let () =
  Alcotest.run "tool_bridge_externalize"
    [
      ( "passthrough modes",
        [
          Alcotest.test_case "no base path = passthrough" `Quick
            test_threshold_default_under;
          Alcotest.test_case "disabled = passthrough" `Quick
            test_disabled_passthrough;
          Alcotest.test_case "threshold env override" `Quick
            test_threshold_env_override;
        ] );
      ( "to_oas_typed_result",
        [
          Alcotest.test_case "small inlined" `Quick test_to_oas_typed_small_inlined;
          Alcotest.test_case "tool name does not bypass externalization" `Quick
            test_tool_identity_does_not_bypass_externalization;
          Alcotest.test_case "error inlined" `Quick test_to_oas_typed_error_inlined;
          Alcotest.test_case "error JSON cannot override typed metadata" `Quick
            test_to_oas_typed_error_ignores_json_metadata;
          Alcotest.test_case "typed workflow rejection is deterministic" `Quick
            test_to_oas_typed_result_preserves_workflow_rejection;
          Alcotest.test_case "typed transient remains recoverable" `Quick
            test_to_oas_typed_result_preserves_transient_failure_class;
          Alcotest.test_case "round-trip through OAS" `Quick
            test_round_trip_through_oas;
        ] );
      ( "externalize",
        [
          Alcotest.test_case "with temp base_path" `Quick
            test_externalize_with_temp_base_path;
          Alcotest.test_case "store failure preserves original bytes" `Quick
            test_blob_store_failure_preserves_original_bytes;
        ] );
    ]
