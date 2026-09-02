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

(* The failure sentences the bridge appends are prompt assets under
   config/prompts; load the real directory so these tests read what a Keeper
   reads, not a fixture that could drift from it. *)
let prompt_dir () =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root -> Filename.concat root "config/prompts"
  | None -> Filename.concat (Sys.getcwd ()) "config/prompts"
;;

let () =
  Prompt_registry.set_markdown_dir (prompt_dir ());
  Masc.Prompt_defaults.init ()
;;

let runtime_failure_next_move =
  "The tool failed inside the runtime, not on your arguments. Identical \
   arguments reproduce it unless the message says the outcome is unknown. \
   Report it as a runtime failure in your answer."
;;

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

(* --- Round-trip via to_agent_core_typed_result on small payloads --- *)

let test_to_agent_core_typed_small_inlined () =
  let small = "small ok" in
  match B.to_agent_core_typed_result (tool_ok ~tool_name:"test" small) with
  | Ok { content; _ } ->
      Alcotest.(check string) "inlined verbatim" small content;
      Alcotest.(check bool) "no marker" false (O.is_marker content)
  | Error _ -> Alcotest.fail "expected Ok"

let test_incident_sized_result_stays_inline () =
  with_temp_base_path (fun dir ->
    let payload = String.make 2_500 'w' in
    match
      B.to_agent_core_typed_result
        ~base_path:dir
        (tool_ok ~tool_name:"WebSearch" payload)
    with
    | Ok { content; _ } ->
      Alcotest.(check string) "2.5KB result stays inline" payload content;
      Alcotest.(check bool) "no blob marker" false (O.is_marker content)
    | Error _ -> Alcotest.fail "expected inline result")

let test_typed_artifact_result_becomes_durable_manifest () =
  with_temp_base_path (fun base_path ->
    let store = Tool_blob_store.create ~base_path in
    let child =
      Tool_blob_store.put_durable
        store
        ~bytes:"exact child output"
        ~mime:"text/plain"
    in
    let structured_content =
      `Assoc
        [ "ok", `Bool true
        ; "output_artifact", O.normalized_artifact_ref_to_json child
        ]
    in
    let result =
      Tool_result.make_ok
        ~tool_name:"Execute"
        ~start_time:0.0
        ~data:structured_content
        ()
      |> B.attach_artifact_manifest ~base_path
    in
    let result =
      match result with
      | Ok result -> result
      | Error { message; _ } -> Alcotest.fail message
    in
    (match B.to_agent_core_typed_result result with
     | Ok { content; _ } ->
       Alcotest.(check bool)
         "manifest marker requires artifact-reader capability"
         false
         (O.is_marker content)
     | Error { message; _ } -> Alcotest.fail message);
    match B.to_agent_core_typed_result ~base_path result with
    | Error { message; _ } -> Alcotest.fail message
    | Ok { content; _ } ->
      (match O.decode_from_agent_core content with
       | O.Not_marker -> Alcotest.fail "typed artifact result stayed unrooted inline"
       | O.Invalid_marker { detail } -> Alcotest.fail detail
       | O.Decoded manifest_ref ->
         Alcotest.(check string)
           "typed manifest media type"
           O.artifact_manifest_mime
           manifest_ref.mime;
         let manifest =
           match Tool_blob_store.fetch store ~sha256:manifest_ref.sha256 with
           | Ok (Some payload) -> Yojson.Safe.from_string payload
           | Ok None -> Alcotest.fail "manifest blob is absent"
           | Error error ->
             Alcotest.fail (Tool_blob_store.fetch_error_to_string error)
         in
         (match O.artifact_manifest_of_json manifest with
          | O.Decoded_artifact_manifest
              { structured_content = restored; artifact_refs; _ } ->
            Alcotest.(check bool)
              "structured result is exact"
              true
              (Yojson.Safe.equal structured_content restored);
            Alcotest.(check int) "one child ownership edge" 1 (List.length artifact_refs);
            Alcotest.(check string)
              "child identity is exact"
              child.sha256
              (List.hd artifact_refs).sha256
          | O.Not_artifact_manifest -> Alcotest.fail "manifest schema is absent"
          | O.Invalid_artifact_manifest { detail } -> Alcotest.fail detail)))

let test_manifest_producer_rejects_mixed_malformed_reference () =
  with_temp_base_path (fun base_path ->
    let child =
      Tool_blob_store.put_durable
        (Tool_blob_store.create ~base_path)
        ~bytes:"valid child"
        ~mime:"text/plain"
    in
    let result =
      Tool_result.make_ok
        ~tool_name:"Execute"
        ~start_time:0.0
        ~data:
          (`Assoc
             [ "valid", O.normalized_artifact_ref_to_json child
             ; "malformed", `Assoc [ "_blob", `Assoc [ "sha256", `String child.sha256 ] ]
             ])
        ()
    in
    match B.attach_artifact_manifest ~base_path result with
    | Ok _ -> Alcotest.fail "mixed malformed artifact data produced a manifest"
    | Error { message; _ } ->
      Alcotest.(check bool)
        "strict producer reports malformed reserved wrapper"
        true
        (String.length message > 0))

let test_bounded_inline_rejects_oversized_result () =
  let payload = String.make (B.default_externalize_threshold_bytes + 1) 'x' in
  match
    B.to_agent_core_typed_result
      ~model_projection:Tool_output.bounded_inline_model_projection
      (tool_ok ~tool_name:"keeper_artifact_read" payload)
  with
  | Ok _ -> Alcotest.fail "oversized bounded-inline result was accepted"
  | Error { message; recoverable; error_class } ->
    Alcotest.(check string)
      "provider receives bounded projection failure"
      "tool output exceeds descriptor budget"
      message;
    Alcotest.(check bool) "bounded projection carries no recovery hint" false recoverable;
    (match error_class with
     | Some Agent_core.Types.Deterministic -> ()
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
        B.to_agent_core_typed_result
          ~base_path:dir
          (tool_ok ~tool_name payload)
      with
      | Ok { content; _ } ->
        Alcotest.(check bool) "externalized" true (O.is_marker content)
      | Error _ -> Alcotest.fail "expected Ok"
    in
    check_tool "opaque_tool_a";
    check_tool "opaque_tool_b")

let test_to_agent_core_typed_error_inlined () =
  match B.to_agent_core_typed_result (tool_error ~tool_name:"test" "fail") with
  | Ok _ -> Alcotest.fail "expected Error"
  | Error { message; recoverable; _ } ->
      Alcotest.(check string)
        "message, then the class and what to do next"
        ("fail\nfailure_class=runtime_failure — " ^ runtime_failure_next_move)
        message;
      Alcotest.(check bool) "default recoverable=false" false recoverable

let test_to_agent_core_typed_error_ignores_json_metadata () =
  let msg =
    {|{"ok":false,"error":"try again","recoverable":true,"error_class":"transient_mutex_contention"}|}
  in
  let tr : Tool_result.result =
    Tool_result.Failed
      { Tool_result.class_ = Tool_result.Runtime_failure
      ; message = msg
      ; data = Yojson.Safe.from_string msg
      ; metadata = None
      ; tool_name = "test"
      ; duration_ms = 0.0
      }
  in
  match B.to_agent_core_typed_result tr with
  | Ok _ -> Alcotest.fail "expected Error"
  | Error { message; recoverable; error_class } ->
      Alcotest.(check string)
        "free-form JSON stays the message; the class line follows it"
        (msg ^ "\nfailure_class=runtime_failure — " ^ runtime_failure_next_move)
        message;
      Alcotest.(check bool) "runtime failure stays non-recoverable" false recoverable;
      (match error_class with
       | Some Agent_core.Types.Unknown -> ()
       | _ -> Alcotest.fail "expected typed runtime failure mapping")

let test_to_agent_core_typed_error_preserves_explicit_metadata () =
  let metadata = `Assoc [ "gate", `Assoc [ "decision", `String "allow" ] ] in
  let tr =
    Tool_result.make_err
      ~tool_name:"test"
      ~class_:Tool_result.Runtime_failure
      ~start_time:0.0
      ~metadata
      "effect failed"
  in
  match B.to_agent_core_typed_result tr with
  | Ok _ -> Alcotest.fail "expected Error"
  | Error { message; _ } ->
    let open Yojson.Safe.Util in
    let payload = Yojson.Safe.from_string message in
    Alcotest.(check string)
      "failure message remains exact"
      "effect failed"
      (payload |> member "message" |> to_string);
    Alcotest.(check string)
      "failed disposition is explicit"
      "failed"
      (payload |> member "masc.tool_disposition" |> to_string);
    Alcotest.(check string)
      "the typed class is a field of the envelope"
      "runtime_failure"
      (payload |> member "failure_class" |> to_string);
    Alcotest.(check string)
      "and so is what to do next"
      runtime_failure_next_move
      (payload |> member "next_move" |> to_string);
    Alcotest.(check string)
      "Gate metadata reaches the provider error"
      "allow"
      (payload
       |> member "masc.payload"
       |> member "gate"
       |> member "decision"
       |> to_string)

let test_to_agent_core_typed_result_preserves_workflow_rejection () =
  let tr =
    Tool_result.error
      ~failure_class:Tool_result.Workflow_rejection
      ~tool_name:"masc_transition"
      ~start_time:0.0
      "Invalid task state: submit_for_verification requires verification evidence"
  in
  match B.to_agent_core_typed_result tr with
  | Ok _ -> Alcotest.fail "expected Error"
  | Error { recoverable; error_class; _ } ->
    Alcotest.(check bool) "workflow rejection is non-recoverable" false recoverable;
    (match error_class with
     | Some Agent_core.Types.Deterministic -> ()
     | _ -> Alcotest.fail "expected deterministic error_class")

let test_to_agent_core_dependency_failure_carries_no_replay_hint () =
  let tr =
    Tool_result.error
      ~failure_class:Tool_result.Dependency_unavailable
      ~tool_name:"tool_search_files"
      ~start_time:0.0
      {|{"ok":false,"error":"mutex contention","failure_class":"dependency_unavailable"}|}
  in
  match B.to_agent_core_typed_result tr with
  | Ok _ -> Alcotest.fail "expected Error"
  | Error { recoverable; error_class; _ } ->
    Alcotest.(check bool) "no replay hint" false recoverable;
    (match error_class with
     | Some Agent_core.Types.Transient -> ()
     | _ -> Alcotest.fail "expected transient diagnostic class")

(* Every class has exactly one sentence, and it reaches the model as the last
   line of the failure content. The sentences are pinned here because they are
   the whole point: a Keeper that sees [dependency_unavailable] and reads that
   other arguments fail the same way stops probing; one that sees
   [policy_rejection] corrects the named field once. *)
let expected_next_moves =
  [ ( Tool_result.Dependency_unavailable
    , "dependency_unavailable"
    , "The dependency this tool needs did not answer. Your arguments were not \
       judged, so the same call with other arguments fails the same way. Do \
       other work or end the turn; it can answer on a later turn." )
  ; ( Tool_result.Policy_rejection
    , "policy_rejection"
    , "Rejected before running. The message above names the field or \
       permission that failed. A call with that field corrected can succeed; a \
       missing permission does not change with different arguments." )
  ; (Tool_result.Runtime_failure, "runtime_failure", runtime_failure_next_move)
  ; ( Tool_result.Workflow_rejection
    , "workflow_rejection"
    , "The current state does not admit this action; it is a rule, not a \
       syntax problem. Read the current state first. The same call succeeds \
       only after the state changes." )
  ; ( Tool_result.Operator_cancelled
    , "operator_cancelled"
    , "An operator stopped this call. It is not re-issued. Say where it \
       stopped in your answer." )
  ]
;;

let test_failure_class_reaches_the_model () =
  List.iter
    (fun (class_, name, sentence) ->
       Alcotest.(check (option string))
         (name ^ " has its sentence")
         (Some sentence)
         (B.failure_next_move class_);
       let plain =
         Tool_result.error ~failure_class:class_ ~tool_name:"t" ~start_time:0.0 "boom"
       in
       (match B.to_agent_core_typed_result plain with
        | Ok _ -> Alcotest.fail "expected Error"
        | Error { message; _ } ->
          Alcotest.(check string)
            (name ^ " plain content")
            ("boom\nfailure_class=" ^ name ^ " — " ^ sentence)
            message);
       let with_metadata =
         Tool_result.make_err
           ~tool_name:"t"
           ~class_
           ~start_time:0.0
           ~metadata:(`Assoc [ "k", `String "v" ])
           "boom"
       in
       match B.to_agent_core_typed_result with_metadata with
       | Ok _ -> Alcotest.fail "expected Error"
       | Error { message; _ } ->
         let open Yojson.Safe.Util in
         let payload = Yojson.Safe.from_string message in
         Alcotest.(check string) (name ^ " envelope class") name
           (payload |> member "failure_class" |> to_string);
         Alcotest.(check string) (name ^ " envelope next move") sentence
           (payload |> member "next_move" |> to_string))
    expected_next_moves
;;

let test_round_trip_through_agent_core () =
  let payload = "inline payload" in
  match B.to_agent_core_typed_result (tool_ok ~tool_name:"test" payload) with
  | Ok { content; _ } ->
      let decoded = O.decode_from_agent_core content in
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
    B.agent_core_tool_of_masc_with_execution_env
      ~name:"occurrence_probe"
      ~description:"capture exact AGENT_CORE invocation"
      ~input_schema:(`Assoc [ "type", `String "object" ])
      (fun execution_env _input ->
         seen_invocation := Agent_core.Tool.Execution_env.invocation execution_env;
         tool_ok ~tool_name:"occurrence_probe" "ok")
  in
  let invocation =
    Agent_core.Tool_contract.Invocation.create
      ~tool_use_id:""
      ~turn:7
      ~completion:Agent_core.Tool_contract.Continue_after_success
      ~schedule:
        { planned_index = 2
        ; batch_index = 0
        ; batch_size = 1
        ; execution_mode = Agent_core.Tool_contract.Serial
        }
  in
  (match Agent_core.Tool.execute ~invocation tool (`Assoc []) with
   | Ok _ -> ()
   | Error _ -> Alcotest.fail "expected successful bridge execution");
  match !seen_invocation with
  | None -> Alcotest.fail "execution environment dropped invocation"
  | Some seen ->
    Alcotest.(check string)
      "blank provider id preserved"
      ""
      (Agent_core.Tool_contract.Invocation.tool_use_id seen);
    Alcotest.(check int) "turn preserved" 7 (Agent_core.Tool_contract.Invocation.turn seen);
    Alcotest.(check int)
      "planned index preserved"
      2
      (Agent_core.Tool_contract.Invocation.planned_index seen)

(* --- Marker encoding round-trip via the bridge --- *)

let test_externalize_with_temp_base_path () =
  with_temp_base_path (fun dir ->
      let payload =
        String.make (B.default_externalize_threshold_bytes + 1) 'z'
      in
      let result = externalize_exn ~base_path:dir payload in
      Alcotest.(check bool) "encoded as marker" true (O.is_marker result);
      match O.decode_from_agent_core result with
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
         B.to_agent_core_typed_result
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
         B.to_agent_core_typed_result
           ~base_path:path
           ~on_externalization_error:(fun { message; _ } ->
             observed := Some message)
           (tool_ok ~tool_name:"test" payload)
       with
       | Ok _ -> Alcotest.fail "projection failure became AGENT_CORE success"
       | Error { message; recoverable; error_class } ->
         Alcotest.(check string)
           "provider error hides storage internals"
           "tool output artifact storage failed"
           message;
         Alcotest.(check bool) "provider gets no replay hint" false recoverable;
         (match error_class with
          | Some Agent_core.Types.Unknown -> ()
          | _ -> Alcotest.fail "expected unknown storage failure"));
      (match !observed with
       | Some diagnostic ->
         Alcotest.(check bool)
           "owning runtime observes exact failure"
           true
           (String.length diagnostic > 0)
       | None -> Alcotest.fail "projection failure observer was not called");
      (match
         B.to_agent_core_typed_result
           ~base_path:path
           (tool_ok ~tool_name:"effectful-test" payload)
       with
       | Ok _ -> Alcotest.fail "projection failure became success"
       | Error { recoverable; error_class; _ } ->
         Alcotest.(check bool)
           "projection carries no recovery hint"
           false
           recoverable;
         (match error_class with
          | Some Agent_core.Types.Unknown -> ()
          | _ -> Alcotest.fail "expected unknown post-effect failure class")))

(* A caller's own metadata has to survive the manifest step, or a projection
   attached before it is silently dropped on its way out. [Execute] used to
   attach the escaped-shell rewrite here; it does not any more, because
   agent_core discards [_meta] where a tool result becomes conversation and
   the advice never reached the caller it was written for. The join is still
   worth pinning for whatever attaches next. *)
let test_existing_metadata_survives_the_manifest () =
  let answered =
    Tool_result.with_metadata
      (`Assoc [ "caller_projection", `String "kept" ])
      (tool_ok "small")
  in
  match B.attach_artifact_manifest ~base_path:"/nonexistent-base" answered with
  | Error { message; _ } -> Alcotest.fail message
  | Ok result ->
    (match Tool_result.metadata result with
     | Some (`Assoc fields) ->
       (match List.assoc_opt "caller_projection" fields with
        | Some (`String "kept") -> ()
        | Some other ->
          Alcotest.failf
            "caller_projection changed on the way through: %s"
            (Yojson.Safe.to_string other)
        | None -> Alcotest.fail "caller_projection was dropped by the manifest step")
     | Some other ->
       Alcotest.failf "metadata stopped being an object: %s" (Yojson.Safe.to_string other)
     | None -> Alcotest.fail "metadata was dropped entirely")
;;

let () =
  Alcotest.run "tool_bridge_externalize"
    [
      ( "passthrough modes",
        [
          Alcotest.test_case "no base path = passthrough" `Quick
            test_threshold_default_under;
        ] );
      ( "to_agent_core_typed_result",
        [
          Alcotest.test_case "small inlined" `Quick test_to_agent_core_typed_small_inlined;
          Alcotest.test_case "2.5KB result stays inline" `Quick
            test_incident_sized_result_stays_inline;
          Alcotest.test_case "typed artifact result owns durable manifest" `Quick
            test_typed_artifact_result_becomes_durable_manifest;
          Alcotest.test_case "manifest producer rejects malformed child" `Quick
            test_manifest_producer_rejects_mixed_malformed_reference;
          Alcotest.test_case "bounded inline rejects oversize" `Quick
            test_bounded_inline_rejects_oversized_result;
          Alcotest.test_case "artifact reader owns inline projection" `Quick
            test_artifact_reader_owns_inline_projection;
          Alcotest.test_case "tool name does not bypass externalization" `Quick
            test_tool_identity_does_not_bypass_externalization;
          Alcotest.test_case "error inlined" `Quick test_to_agent_core_typed_error_inlined;
          Alcotest.test_case "error JSON cannot override typed metadata" `Quick
            test_to_agent_core_typed_error_ignores_json_metadata;
          Alcotest.test_case "error preserves explicit metadata" `Quick
            test_to_agent_core_typed_error_preserves_explicit_metadata;
          Alcotest.test_case "typed workflow rejection is deterministic" `Quick
            test_to_agent_core_typed_result_preserves_workflow_rejection;
          Alcotest.test_case "dependency failure carries no replay hint" `Quick
            test_to_agent_core_dependency_failure_carries_no_replay_hint;
          Alcotest.test_case "failure class reaches the model" `Quick
            test_failure_class_reaches_the_model;
          Alcotest.test_case "round-trip through AGENT_CORE" `Quick
            test_round_trip_through_agent_core;
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
          Alcotest.test_case "existing metadata survives the manifest" `Quick
            test_existing_metadata_survives_the_manifest;
        ] );
    ]
