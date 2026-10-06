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
  Tool_result.make_ok ~tool_name ~start_time:(Tool_timing.start ()) ~data:(`String message) ()
;;

let tool_error ?(tool_name = "") message =
  Tool_result.make_err
    ~tool_name
    ~class_:Tool_result.Runtime_failure
    ~start_time:(Tool_timing.start ())
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
        ~start_time:(Tool_timing.start ())
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
        ~start_time:(Tool_timing.start ())
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
    (* The refusal names the limit and the byte counts, so the model and the
       operator can tell an oversized result from a storage failure. *)
    Alcotest.(check string)
      "provider receives bounded projection failure"
      (Printf.sprintf
         "inline tool output exceeds descriptor budget (%d > %d bytes)"
         (String.length payload)
         B.default_externalize_threshold_bytes)
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

let test_claude_declared_ceiling_keeps_the_same_31558_byte_result_inline () =
  with_temp_base_path (fun base_path ->
    let payload = String.make 31_558 'q' in
    let result = tool_ok ~tool_name:"bounded_fixture" payload in
    let project threshold_bytes =
      match
        B.to_agent_core_typed_result
          ~base_path
          ~model_projection:(O.Store_above { threshold_bytes })
          result
      with
      | Ok { content; _ } -> content
      | Error { message; _ } -> Alcotest.fail message
    in
    let old_content = project Common.max_tool_result_wire_bytes in
    let declared_content =
      project Runtime_execution.claude_code_inline_result_bytes
    in
    match O.decode_from_agent_core old_content with
    | O.Not_marker -> Alcotest.fail "the old ceiling must spill"
    | O.Invalid_marker { detail } -> Alcotest.fail detail
    | O.Decoded reference ->
      let store = Tool_blob_store.create ~base_path in
      (match Tool_blob_store.fetch store ~sha256:reference.sha256 with
       | Ok (Some stored) ->
         Alcotest.(check string) "spilled bytes equal inline bytes" stored declared_content
       | Ok None -> Alcotest.fail "the spilled result is absent"
       | Error error -> Alcotest.fail (Tool_blob_store.fetch_error_to_string error));
      Alcotest.(check bool) "the declared ceiling keeps the result inline"
        false (O.is_marker declared_content))
;;

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

let test_stored_failure_keeps_immediate_context () =
  with_temp_base_path (fun base_path ->
    let store = Tool_blob_store.create ~base_path in
    let expected_preview =
      "failure_class=runtime_failure — " ^ runtime_failure_next_move
    in
    let check result =
      match B.to_agent_core_typed_result ~base_path
              ~model_projection:(O.Store_above { threshold_bytes = 64 }) result with
      | Ok _ -> Alcotest.fail "stored failure must remain an error"
      | Error { message; _ } ->
        match O.decode_from_agent_core message with
        | O.Not_marker -> Alcotest.fail "expected stored failure reference"
        | O.Invalid_marker { detail } -> Alcotest.fail detail
        | O.Decoded reference ->
          Alcotest.(check string) "failure guidance is visible before reading artifact"
            expected_preview reference.preview;
          match Tool_blob_store.fetch store ~sha256:reference.sha256 with
          | Ok (Some _) -> ()
          | Ok None -> Alcotest.fail "stored failure payload is missing"
          | Error error -> Alcotest.fail (Tool_blob_store.fetch_error_to_string error)
    in
    check (tool_error ~tool_name:"Execute" (String.make 1024 'e'));
    let child = Tool_blob_store.put_durable store ~bytes:"process stderr" ~mime:"text/plain" in
    let result = Tool_result.make_err ~tool_name:"Execute"
        ~class_:Tool_result.Runtime_failure ~start_time:(Tool_timing.start ())
        ~data:(`Assoc [ "stderr", O.normalized_artifact_ref_to_json child ])
        "process failed" in
    match B.attach_artifact_manifest ~base_path result with
    | Ok result -> check result
    | Error { message; _ } -> Alcotest.fail message)

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
      { Tool_result.effect_disposition = Tool_result.Effect_outcome_unknown
       ; class_ = Tool_result.Runtime_failure
      ; message = msg
      ; data_source = Tool_result.Explicit_data (Yojson.Safe.from_string msg)
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

let test_failure_recovery_data_reaches_model () =
  let data = `Assoc
      [ "recovery_id", `String "recovery-7"
      ; "next_call", `Assoc [ "tool", `String "status"; "id", `String "recovery-7" ] ]
  in
  List.iter (fun metadata ->
    let result = Tool_result.make_err ~tool_name:"publish"
        ~class_:Tool_result.Workflow_rejection ~start_time:(Tool_timing.start ())
        ~data ?metadata "publication needs recovery" in
    match B.to_agent_core_typed_result result with
    | Ok _ -> Alcotest.fail "expected failure"
    | Error { message; _ } ->
      let open Yojson.Safe.Util in
      let payload = Yojson.Safe.from_string message in
      Alcotest.(check bool) "recovery payload reaches model content" true
        (Yojson.Safe.equal data (payload |> member "data"));
      Alcotest.(check string) "typed failure stays explicit" "workflow_rejection"
        (payload |> member "failure_class" |> to_string);
      match metadata with
      | None -> ()
      | Some expected ->
        Alcotest.(check bool) "independent metadata is retained" true
          (Yojson.Safe.equal expected (payload |> member "masc.payload")))
    [ None; Some (`Assoc [ "upstream_http_status", `Int 503 ]) ]

let test_to_agent_core_typed_error_preserves_explicit_metadata () =
  let metadata = `Assoc [ "upstream_http_status", `Int 503 ] in
  let tr =
    Tool_result.make_err
      ~tool_name:"test"
      ~class_:Tool_result.Runtime_failure
      ~start_time:(Tool_timing.start ())
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
    Alcotest.(check int)
      "producer metadata reaches the provider error"
      503
      (payload
       |> member "masc.payload"
       |> member "upstream_http_status"
       |> to_int)

let test_to_agent_core_typed_result_preserves_workflow_rejection () =
  let tr =
    Tool_result.error
      ~failure_class:Tool_result.Workflow_rejection
      ~tool_name:"masc_transition"
      ~start_time:(Tool_timing.start ())
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
      ~start_time:(Tool_timing.start ())
      {|{"ok":false,"error":"mutex contention","failure_class":"dependency_unavailable"}|}
  in
  match B.to_agent_core_typed_result tr with
  | Ok _ -> Alcotest.fail "expected Error"
  | Error { recoverable; error_class; _ } ->
    Alcotest.(check bool) "no replay hint" false recoverable;
    (match error_class with
     | Some Agent_core.Types.Transient -> ()
     | _ -> Alcotest.fail "expected transient diagnostic class")

(* Each class supplies model-facing guidance from the real prompt asset.
   Dependency classification alone cannot establish retryability or whether
   the upstream accepted the resource/authentication in this request. *)
let expected_next_moves =
  [ ( Tool_result.Dependency_unavailable
    , "dependency_unavailable"
    , "An external dependency could not fulfill this call. Read the failure \
       details: the cause may be transport, authentication, resource \
       availability, or a remote service response. This class alone does not \
       establish retryability. Use the stated cause to choose the next action; \
       do not assume that changing arguments or waiting will resolve it." )
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
         Tool_result.error ~failure_class:class_ ~tool_name:"t" ~start_time:(Tool_timing.start ()) "boom"
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
           ~start_time:(Tool_timing.start ())
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

let test_post_effect_peer_artifact_remains_delegatable () =
  with_temp_base_path (fun base_path ->
    let bytes = "already exported peer artifact" in
    let store = Tool_blob_store.create ~base_path in
    let blob = Tool_blob_store.put_durable
        store ~bytes ~mime:"application/octet-stream" in
    let artifact =
      match Masc.Keeper_peer_artifact_ref.make ~blob
              ~filename:"analysis.bin" ~purpose:"peer handoff" with
      | Ok value -> value
      | Error detail -> Alcotest.fail detail
    in
    let data = `Assoc ["artifact", Masc.Keeper_peer_artifact_ref.to_json artifact] in
    let exported = Tool_result.make_ok ~tool_name:"keeper_artifact_transfer"
        ~start_time:(Tool_timing.start ()) ~data () in
    (* Preserve the durable export while making the real manifest writer fail.
       Restore access before the model consumes the resulting failure. *)
    let root = Tool_blob_store.root_dir store in
    let retained = root ^ ".retained" in
    Unix.rename root retained;
    Fun.protect ~finally:(fun () ->
      if Sys.file_exists root then Unix.unlink root;
      Unix.rename retained root) (fun () ->
        let blocked = open_out_bin root in
        close_out blocked;
        match B.attach_artifact_manifest ~base_path exported with
        | Ok _ -> Alcotest.fail "blocked manifest storage unexpectedly succeeded"
        | Error { kind = B.Artifact_storage_failure; _ } -> ()
        | Error { kind = B.Inline_budget_exceeded; message } ->
            Alcotest.failf "expected storage failure, got budget refusal: %s" message);
    let failed = Tool_result.make_err
        ~tool_name:"keeper_artifact_transfer" ~class_:Tool_result.Runtime_failure
        ~start_time:(Tool_timing.start ()) ~data
        ~effect_disposition:Tool_result.Proven_post_effect
        "Export applied, result manifest unavailable" in
    let response =
      match B.to_agent_core_typed_result ~base_path
              ~on_externalization_error:(fun _ ->
                Alcotest.fail "post-effect recovery must not repeat projection") failed with
      | Ok _ -> Alcotest.fail "post-effect failure became success"
      | Error {message; recoverable; _} ->
          Alcotest.(check bool) "no effect replay hint" false recoverable;
          Yojson.Safe.from_string message
    in
    let open Yojson.Safe.Util in
    Alcotest.(check string) "applied effect remains explicit" "proven_post_effect"
      (response |> member "effect_disposition" |> to_string);
    Alcotest.(check bool) "producer recovery payload is intact" true
      (Yojson.Safe.equal data (response |> member "data"));
    let recovered =
      match Masc.Keeper_peer_artifact.reference
              (response |> member "data" |> member "artifact") with
      | Ok reference -> reference
      | Error detail -> Alcotest.failf "model-visible artifact cannot be delegated: %s" detail
    in
    Alcotest.(check string) "filename preserved" "analysis.bin" recovered.filename;
    Alcotest.(check string) "purpose preserved" "peer handoff" recovered.purpose;
    match Masc.Keeper_peer_artifact.fetch
            ~config:(Masc.Workspace.default_config base_path) recovered with
    | Ok actual -> Alcotest.(check string) "reuse original durable bytes" bytes actual
    | Error detail -> Alcotest.fail detail)

let test_post_effect_manifest_failure_respects_each_projection () =
  List.iter (fun model_projection ->
    with_temp_base_path (fun base_path ->
      let store = Tool_blob_store.create ~base_path in
      let blob = Tool_blob_store.put_durable store ~bytes:"applied recovery bytes" ~mime:"text/plain" in
      let ceiling = O.inline_ceiling_bytes model_projection in
      let reference = O.normalized_artifact_ref_to_json blob in
      let shortest = Tool_blob_store.put_durable store ~bytes:"0" ~mime:"text/plain"
        |> O.normalized_artifact_ref_to_json in
      let reference_bytes = String.length (Yojson.Safe.to_string shortest) in
      let many = List.init (ceiling / reference_bytes + 1) (fun index ->
        Tool_blob_store.put_durable store ~bytes:(string_of_int index) ~mime:"text/plain"
        |> O.normalized_artifact_ref_to_json) in
      let large_preview = O.with_preview blob (String.make (ceiling + 1) 'p')
        |> O.normalized_artifact_ref_to_json in
      List.iter (fun (name, data, expect_omitted) ->
        let exported = Tool_result.make_ok ~tool_name:"keeper_ide_annotate"
          ~start_time:(Tool_timing.start ()) ~data () in
        let root = Tool_blob_store.root_dir store in
        let retained = root ^ ".retained" in
        Unix.rename root retained;
        Fun.protect ~finally:(fun () ->
          if Sys.file_exists root then Unix.unlink root;
          Unix.rename retained root) (fun () ->
            let blocked = open_out_bin root in close_out blocked;
            match B.attach_artifact_manifest ~base_path exported with
            | Error { kind = B.Artifact_storage_failure; _ } -> ()
            | Error _ -> Alcotest.fail "expected actual manifest storage failure"
            | Ok _ -> Alcotest.fail "blocked manifest unexpectedly succeeded");
        let failed = Tool_result.make_err ~tool_name:"keeper_ide_annotate"
          ~class_:Tool_result.Runtime_failure ~start_time:(Tool_timing.start ()) ~data
          ~effect_disposition:Tool_result.Proven_post_effect "Already applied" in
        match B.to_agent_core_typed_result ~base_path ~model_projection
          ~on_externalization_error:(fun _ -> Alcotest.fail "must not repeat projection") failed with
        | Ok _ -> Alcotest.fail "applied failure became success"
        | Error { message; recoverable; _ } ->
          Alcotest.(check bool) (name ^ " stays within the typed ceiling") true
            (String.length message <= ceiling);
          Alcotest.(check bool) (name ^ " forbids replay") false recoverable;
          let response = Yojson.Safe.from_string message in
          let open Yojson.Safe.Util in
          Alcotest.(check string) "applied effect remains explicit" "proven_post_effect"
            (response |> member "effect_disposition" |> to_string);
          Alcotest.(check bool) "raw producer payload explicitly omitted" true
            (response |> member "data_omitted" |> to_bool);
          Alcotest.(check bool) "raw producer data is absent" true
            (member "data" response = `Null);
          Alcotest.(check bool) "current target fallback and no-repeat instruction remain" true
            (String_util.contains_substring message "current target"
             && String_util.contains_substring message "do not repeat");
          Alcotest.(check bool) "omitted handle count is explicit" expect_omitted
            (response |> member "artifact_refs_omitted" |> to_int > 0);
          let recovered = response |> member "artifact_refs" |> to_list in
          Alcotest.(check bool) "at least one canonical recovery handle survives" true
            (recovered <> []);
          List.iter (fun json ->
            match O.normalized_artifact_ref_of_json json with
            | O.Decoded_normalized_artifact_ref reference ->
              (match Tool_blob_store.fetch store ~sha256:reference.sha256 with
               | Ok (Some _) -> ()
               | _ -> Alcotest.fail "bounded handle cannot retrieve original bytes")
            | _ -> Alcotest.fail "bounded handle is not normalized") recovered)
        [ "large inserted body", `Assoc ["inserted", `String
            (String.make (2 * O.inline_ceiling_bytes O.agent_core_model_projection) 'i');
            "edit_snapshots", `List [reference]], false
        ; "many handles", `Assoc ["artifacts", `List many], true
        ; "large handle preview", `Assoc ["artifact", large_preview], false
        ])) [O.default_model_projection; O.agent_core_model_projection]

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
         (* The boundary phrase names where the failure happened; the typed
            cause follows it. Dropping the cause left the model and the
            operator with a bare label they could not act on. *)
         (match !observed with
          | Some diagnostic ->
            Alcotest.(check string)
              "provider error names the boundary and keeps the cause"
              ("tool output artifact storage failed: " ^ String.trim diagnostic)
              message
          | None -> Alcotest.fail "projection failure observer was not called");
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
          Alcotest.test_case "31558 bytes spill then stay inline at Claude ceiling" `Quick
            test_claude_declared_ceiling_keeps_the_same_31558_byte_result_inline;
          Alcotest.test_case "tool name does not bypass externalization" `Quick
            test_tool_identity_does_not_bypass_externalization;
          Alcotest.test_case "stored failure keeps immediate guidance" `Quick
            test_stored_failure_keeps_immediate_context;
          Alcotest.test_case "error inlined" `Quick test_to_agent_core_typed_error_inlined;
          Alcotest.test_case "error JSON cannot override typed metadata" `Quick
            test_to_agent_core_typed_error_ignores_json_metadata;
          Alcotest.test_case "error preserves explicit metadata" `Quick
            test_to_agent_core_typed_error_preserves_explicit_metadata;
          Alcotest.test_case "failure recovery data reaches model" `Quick
            test_failure_recovery_data_reaches_model;
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
          Alcotest.test_case "post-effect peer artifact remains delegatable" `Quick
            test_post_effect_peer_artifact_remains_delegatable;
          Alcotest.test_case "post-effect manifest failure respects both projection budgets" `Quick
            test_post_effect_manifest_failure_respects_each_projection;
          Alcotest.test_case "bounded read page is not nested" `Quick
            test_bounded_read_page_is_not_nested;
          Alcotest.test_case "store failure is typed" `Quick
            test_blob_store_failure_is_typed;
          Alcotest.test_case "existing metadata survives the manifest" `Quick
            test_existing_metadata_survives_the_manifest;
        ] );
    ]
