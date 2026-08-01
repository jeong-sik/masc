(** Tests for [Tool_bridge.maybe_externalize].

    Pins the threshold contract:
    - small payloads (< threshold) flow through verbatim
    - large payloads (> threshold) are stored and replaced with
      [Tool_output.Stored] blob marker
    - boundary cases (exactly == threshold) follow [<=] semantics
    - externalization is skipped when no explicit [base_path] is supplied
    - a blob-store failure returns a typed projection error
    - tool identity and free-form error JSON never change bridge behavior

    The actual blob store is exercised in [test_tool_blob_store]; here we
    only verify the bridge's wiring decisions. *)

module B = Masc.Tool_bridge
module O = Tool_output

let externalize_exn ?base_path value =
  match B.maybe_externalize ?base_path value with
  | Ok output -> output
  | Error { message; _ } -> Alcotest.fail message

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

let test_threshold_default_under () =
  let small = "short payload" in
  let result = externalize_exn small in
  Alcotest.(check string) "small unchanged" small result;
  let large = String.make (B.default_externalize_threshold_bytes + 1) 'x' in
  let result_large = externalize_exn large in
  Alcotest.(check string) "large unchanged when no base path" large result_large

(* --- Round-trip via to_oas_typed_result on small payloads --- *)

let test_to_oas_typed_small_inlined () =
  let small = "small ok" in
  match B.to_oas_typed_result (tool_ok ~tool_name:"test" small) with
  | Ok { content; _ } ->
      Alcotest.(check string) "inlined verbatim" small content;
      Alcotest.(check bool) "no marker" false (O.is_marker content)
  | Error _ -> Alcotest.fail "expected Ok"

let test_incident_sized_result_stays_inline () =
  with_temp_base_path (fun dir ->
    let payload = String.make 2_500 'w' in
    match
      B.to_oas_typed_result
        ~base_path:dir
        (tool_ok ~tool_name:"WebSearch" payload)
    with
    | Ok { content; _ } ->
      Alcotest.(check string) "2.5KB result stays inline" payload content;
      Alcotest.(check bool) "no blob marker" false (O.is_marker content)
    | Error _ -> Alcotest.fail "expected inline result")

let test_bounded_inline_rejects_oversized_result () =
  let payload = String.make (B.default_externalize_threshold_bytes + 1) 'x' in
  match
    B.to_oas_typed_result
      ~model_projection:Tool_output.bounded_inline_model_projection
      (tool_ok ~tool_name:"keeper_artifact_read" payload)
  with
  | Ok _ -> Alcotest.fail "oversized bounded-inline result was accepted"
  | Error { message; recoverable; error_class } ->
    Alcotest.(check string)
      "provider receives bounded projection failure"
      "tool output exceeds descriptor budget"
      message;
    Alcotest.(check bool) "bounded projection is not retryable" false recoverable;
    (match error_class with
     | Some Agent_sdk.Types.Deterministic -> ()
     | _ -> Alcotest.fail "bounded projection failure is not deterministic")

let test_artifact_reader_owns_inline_projection () =
  let descriptor =
    Masc.Keeper_tool_descriptor.all_descriptors ()
    |> List.find_opt (fun (descriptor : Masc.Keeper_tool_descriptor.t) ->
      String.equal descriptor.internal_name "keeper_artifact_read")
  in
  match descriptor with
  | None -> Alcotest.fail "artifact reader descriptor is missing"
  | Some { model_output_projection = Tool_output.Inline_up_to { maximum_bytes }; _ } ->
    Alcotest.(check int)
      "artifact reader uses canonical output budget"
      B.default_externalize_threshold_bytes
      maximum_bytes
  | Some { model_output_projection = Tool_output.Store_above _; _ } ->
    Alcotest.fail "artifact reader can still create a nested blob"

let test_tool_identity_does_not_bypass_externalization () =
  with_temp_base_path (fun dir ->
    let payload = String.make (B.default_externalize_threshold_bytes + 1) 'b' in
    let check_tool tool_name =
      match
        B.to_oas_typed_result
          ~base_path:dir
          (tool_ok ~tool_name payload)
      with
      | Ok { content; _ } ->
        Alcotest.(check bool) "externalized" true (O.is_marker content)
      | Error _ -> Alcotest.fail "expected Ok"
    in
    check_tool "opaque_tool_a";
    check_tool "opaque_tool_b")

let test_to_oas_typed_error_inlined () =
  match B.to_oas_typed_result (tool_error ~tool_name:"test" "fail") with
  | Ok _ -> Alcotest.fail "expected Error"
  | Error { message; recoverable; _ } ->
      Alcotest.(check string) "message" "fail" message;
      Alcotest.(check bool) "default recoverable=false" false recoverable

let test_to_oas_typed_error_ignores_json_metadata () =
  let msg =
    {|{"ok":false,"error":"try again","recoverable":true,"error_class":"transient_mutex_contention"}|}
  in
  let tr : Tool_result.result =
    Tool_result.Failed
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
  let payload = "inline payload" in
  match B.to_oas_typed_result (tool_ok ~tool_name:"test" payload) with
  | Ok { content; _ } ->
      let decoded = O.decode_from_oas content in
      (match decoded with
       | O.Not_marker ->
           (* Not a marker: the raw content is the payload itself. *)
           Alcotest.(check string) "inline preserved" payload content
       | O.Decoded _ ->
           Alcotest.fail "did not expect Decoded when externalize=0"
       | O.Invalid_marker { detail } ->
           Alcotest.failf
             "did not expect Invalid_marker when externalize=0: %s" detail)
  | Error _ -> Alcotest.fail "expected Ok"

let test_execution_env_preserves_exact_invocation () =
  let seen_invocation = ref None in
  let tool =
    B.oas_tool_of_masc_with_execution_env
      ~name:"occurrence_probe"
      ~description:"capture exact OAS invocation"
      ~input_schema:(`Assoc [ "type", `String "object" ])
      (fun execution_env _input ->
         seen_invocation := Agent_sdk.Tool.Execution_env.invocation execution_env;
         tool_ok ~tool_name:"occurrence_probe" "ok")
  in
  let invocation =
    Agent_sdk.Tool_contract.Invocation.create
      ~tool_use_id:""
      ~turn:7
      ~completion:Agent_sdk.Tool_contract.Continue_after_success
      ~schedule:
        { planned_index = 2
        ; batch_index = 0
        ; batch_size = 1
        ; execution_mode = Agent_sdk.Tool_contract.Serial
        }
  in
  (match Agent_sdk.Tool.execute ~invocation tool (`Assoc []) with
   | Ok _ -> ()
   | Error _ -> Alcotest.fail "expected successful bridge execution");
  match !seen_invocation with
  | None -> Alcotest.fail "execution environment dropped invocation"
  | Some seen ->
    Alcotest.(check string)
      "blank provider id preserved"
      ""
      (Agent_sdk.Tool_contract.Invocation.tool_use_id seen);
    Alcotest.(check int) "turn preserved" 7 (Agent_sdk.Tool_contract.Invocation.turn seen);
    Alcotest.(check int)
      "planned index preserved"
      2
      (Agent_sdk.Tool_contract.Invocation.planned_index seen)

(* --- Marker encoding round-trip via the bridge --- *)

let test_externalize_with_temp_base_path () =
  with_temp_base_path (fun dir ->
      let payload =
        String.make (B.default_externalize_threshold_bytes + 1) 'z'
      in
      let result = externalize_exn ~base_path:dir payload in
      Alcotest.(check bool) "encoded as marker" true (O.is_marker result);
      match O.decode_from_oas result with
      | O.Decoded { sha256; bytes; _ } ->
        Alcotest.(check int) "byte count" (String.length payload) bytes;
        Alcotest.(check int) "sha length" 64 (String.length sha256)
      | O.Not_marker -> Alcotest.fail "expected Decoded after externalize"
      | O.Invalid_marker { detail } ->
          Alcotest.failf
            "expected Decoded after externalize, got Invalid_marker: %s"
            detail)

let test_bounded_read_page_is_not_nested () =
  with_temp_base_path (fun _dir ->
    let request : Masc.Keeper_artifact_read.request =
      { sha256 = String.make 64 'a'
      ; offset = 0
      ; max_bytes = Masc.Keeper_artifact_read.maximum_max_bytes
      }
    in
    let page =
      match
        Masc.Keeper_artifact_read.For_testing.page
          request
          (String.make Masc.Keeper_artifact_read.maximum_max_bytes '\000')
      with
      | Ok page -> page
      | Error error -> Alcotest.fail error
    in
    let output =
      page
      |> Masc.Keeper_artifact_read.For_testing.page_to_json
      |> Yojson.Safe.to_string
    in
    Alcotest.(check bool)
      "worst-case bounded page fits inline contract"
      true
      (String.length output <= B.default_externalize_threshold_bytes);
    Alcotest.(check bool)
      "page advances beyond the removed 256-byte workaround"
      true
      (page.next_offset > 256);
    Alcotest.(check string)
      "bounded page remains provider-visible"
      output
      (match
         B.to_oas_typed_result
           ~model_projection:Tool_output.bounded_inline_model_projection
           (tool_ok ~tool_name:"keeper_artifact_read" output)
       with
       | Ok { content; _ } -> content
       | Error { message; _ } -> Alcotest.fail message))

let test_blob_store_failure_is_typed () =
  let path = Filename.temp_file "masc_bridge_not_a_directory" "" in
  let restore () = Sys.remove path in
  Fun.protect
    ~finally:restore
    (fun () ->
      let payload =
        String.make (B.default_externalize_threshold_bytes + 1) '\000'
      in
      (match B.maybe_externalize ~base_path:path payload with
       | Ok _ -> Alcotest.fail "failed store returned provider content"
       | Error { message; _ } ->
         Alcotest.(check bool)
           "storage failure is visible"
           true
           (String.length message > 0));
      let observed = ref None in
      (match
         B.to_oas_typed_result
           ~base_path:path
           ~on_externalization_error:(fun { message; _ } ->
             observed := Some message)
           (tool_ok ~tool_name:"test" payload)
       with
       | Ok _ -> Alcotest.fail "projection failure became OAS success"
       | Error { message; recoverable; error_class } ->
         Alcotest.(check string)
           "provider error hides storage internals"
           "tool output artifact storage failed"
           message;
         Alcotest.(check bool) "provider may retry" true recoverable;
         (match error_class with
          | Some Agent_sdk.Types.Transient -> ()
          | _ -> Alcotest.fail "expected transient storage failure"));
      (match !observed with
       | Some diagnostic ->
         Alcotest.(check bool)
           "owning runtime observes exact failure"
           true
           (String.length diagnostic > 0)
       | None -> Alcotest.fail "projection failure observer was not called");
      (match
         B.to_oas_typed_result
           ~base_path:path
           ~externalization_error_recoverable:false
           (tool_ok ~tool_name:"effectful-test" payload)
       with
       | Ok _ -> Alcotest.fail "non-retryable projection failure became success"
       | Error { recoverable; error_class; _ } ->
         Alcotest.(check bool)
           "owning tool retry policy is preserved"
           false
           recoverable;
         (match error_class with
          | Some Agent_sdk.Types.Unknown -> ()
          | _ -> Alcotest.fail "expected unknown post-effect failure class")))

let () =
  Alcotest.run "tool_bridge_externalize"
    [
      ( "passthrough modes",
        [
          Alcotest.test_case "no base path = passthrough" `Quick
            test_threshold_default_under;
        ] );
      ( "to_oas_typed_result",
        [
          Alcotest.test_case "small inlined" `Quick test_to_oas_typed_small_inlined;
          Alcotest.test_case "2.5KB result stays inline" `Quick
            test_incident_sized_result_stays_inline;
          Alcotest.test_case "bounded inline rejects oversize" `Quick
            test_bounded_inline_rejects_oversized_result;
          Alcotest.test_case "artifact reader owns inline projection" `Quick
            test_artifact_reader_owns_inline_projection;
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
          Alcotest.test_case "execution env preserves exact invocation" `Quick
            test_execution_env_preserves_exact_invocation;
        ] );
      ( "externalize",
        [
          Alcotest.test_case "with temp base_path" `Quick
            test_externalize_with_temp_base_path;
          Alcotest.test_case "bounded read page is not nested" `Quick
            test_bounded_read_page_is_not_nested;
          Alcotest.test_case "store failure is typed" `Quick
            test_blob_store_failure_is_typed;
        ] );
    ]
