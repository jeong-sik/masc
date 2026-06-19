open Tool_job
open Tool_event

(** Initialize the full tool registry so [make] can look up schemas and
    metadata for real tools like [masc_status]. *)
let init () = Masc_test_deps.init_keeper_tool_registry ()

let sample_schema =
  `Assoc
    [ "type", `String "object"
    ; "properties", `Assoc [ "goal_id", `Assoc [ "type", `String "string" ] ]
    ; "required", `List [ `String "goal_id" ]
    ]

let test_schema_hash_is_stable () =
  let h1 = schema_hash_of_yojson sample_schema in
  let h2 =
    schema_hash_of_yojson
      (`Assoc
         [ "required", `List [ `String "goal_id" ]
         ; "type", `String "object"
         ; "properties", `Assoc [ "goal_id", `Assoc [ "type", `String "string" ] ]
         ])
  in
  Alcotest.(check string) "schema hash stable under key reordering" h1 h2
;;

let test_make_reads_tool_metadata () =
  init ();
  let job = make ~batch_id:"batch_1" ~tool_name:"masc_status" ~input_json:(`Assoc []) () in
  Alcotest.(check bool) "masc_status is read-only" true job.read_only;
  Alcotest.(check (list string)) "read-only default has no writer lock" [] job.resource_keys;
  Alcotest.(check string) "batch_id carried" "batch_1" job.batch_id;
  Alcotest.(check bool) "schema hash is non-empty" true (String.length job.schema_hash > 0)
;;

let test_policy_verdict_roundtrip () =
  let cases = [ Approved; Pending "awaiting approval"; Denied "catastrophic floor" ] in
  List.iter
    (fun v ->
      let json = Tool_job.to_yojson { (make ~job_id:"j" ~batch_id:"b" ~tool_name:"masc_status" ~input_json:(`Assoc []) ()) with approval = v } in
      let job = Tool_job.of_yojson json |> Result.get_ok in
      Alcotest.(check bool) "policy verdict roundtrip" true (job.approval = v))
    cases
;;

let test_job_roundtrip () =
  init ();
  let job =
    make
      ~job_id:"job_1"
      ~turn_id:"turn_1"
      ~goal_id:"goal_1"
      ~keeper_id:"keeper_1"
      ~batch_id:"batch_1"
      ~tool_name:"masc_goal_list"
      ~input_json:(`Assoc [ "limit", `Int 10 ])
      ~approval:(Pending "operator")
      ~attempt:2
      ()
  in
  let json = Tool_job.to_yojson job in
  let job' = Tool_job.of_yojson json |> Result.get_ok in
  Alcotest.(check bool) "job roundtrip" true (job = job')
;;

let test_job_roundtrip_accepts_missing_option_fields () =
  let json =
    `Assoc
      [ "job_id", `String "job_legacy"
      ; "batch_id", `String "batch_legacy"
      ; "tool_name", `String "unknown_tool"
      ; "schema_hash", `String "hash"
      ; "input_json", `Assoc []
      ; "read_only", `Bool false
      ; "resource_keys", `List [ `String "write:any" ]
      ; "approval", Tool_job.policy_verdict_to_yojson Approved
      ; "attempt", `Int 1
      ]
  in
  let job = Tool_job.of_yojson json |> Result.get_ok in
  Alcotest.(check (option string)) "missing turn_id defaults None" None job.turn_id;
  Alcotest.(check (option string)) "missing goal_id defaults None" None job.goal_id;
  Alcotest.(check (option string)) "missing keeper_id defaults None" None job.keeper_id;
  Alcotest.(check (option string)) "missing tool_version defaults None" None job.tool_version;
  Alcotest.(check (option string)) "missing idempotency_key defaults None" None job.idempotency_key;
  Alcotest.(check (option int)) "missing deadline_ms defaults None" None job.deadline_ms
;;

let test_resource_key_inference () =
  let check ~tool_name ~input ~expected =
    let actual =
      default_resource_keys_of_tool
        ~read_only:(String.equal tool_name "masc_status")
        ~tool_name
        ~input_json:input
    in
    Alcotest.(check (list string)) (Printf.sprintf "%s resource keys" tool_name) expected actual
  in
  check
    ~tool_name:"masc_status"
    ~input:(`Assoc [])
    ~expected:[];
  check
    ~tool_name:"tool_edit_file"
    ~input:(`Assoc [ "path", `String "lib/foo.ml" ])
    ~expected:[ "write:any" ];
  check
    ~tool_name:"unknown_tool"
    ~input:(`Assoc [])
    ~expected:[ "write:any" ]
;;

let test_event_roundtrip () =
  let events =
    [ Batch_created { batch_id = "batch_1"; parent_turn_id = Some "turn_1"; parent_goal_id = None }
    ; Job_scheduled "job_1"
    ; Job_started "job_1"
    ; Job_progress ("job_1", `Assoc [ "percent", `Int 50 ])
    ; Job_succeeded ("job_1", `Assoc [ "status", `String "ok" ])
    ; Job_failed ("job_1", Transient, "timeout")
    ; Job_cancelled ("job_1", "operator")
    ; Batch_finished ("batch_1", "partial_success")
    ]
  in
  List.iter
    (fun ev ->
      let json = Tool_event.to_yojson ev in
      let ev' = Tool_event.of_yojson json |> Result.get_ok in
      Alcotest.(check bool) "event roundtrip" true (ev = ev'))
    events
;;

let test_event_batch_created_accepts_missing_option_fields () =
  let json = `List [ `String "Batch_created"; `Assoc [ "batch_id", `String "batch_legacy" ] ] in
  match Tool_event.of_yojson json |> Result.get_ok with
  | Batch_created b ->
    Alcotest.(check string) "batch id" "batch_legacy" b.batch_id;
    Alcotest.(check (option string)) "parent turn default" None b.parent_turn_id;
    Alcotest.(check (option string)) "parent goal default" None b.parent_goal_id
  | _ -> Alcotest.fail "expected Batch_created"
;;

let test_event_batch_id_exhaustive_helpers () =
  let check name expected event =
    Alcotest.(check (option string)) name expected (Tool_event.batch_id event)
  in
  check "batch created" (Some "batch_1") (Batch_created { batch_id = "batch_1"; parent_turn_id = None; parent_goal_id = None });
  check "batch finished" (Some "batch_1") (Batch_finished ("batch_1", "ok"));
  check "job scheduled has no batch id" None (Job_scheduled "job_1");
  check "job started has no batch id" None (Job_started "job_1");
  check "job progress has no batch id" None (Job_progress ("job_1", `Assoc []));
  check "job succeeded has no batch id" None (Job_succeeded ("job_1", `Assoc []));
  check "job failed has no batch id" None (Job_failed ("job_1", Runtime, "boom"));
  check "job cancelled has no batch id" None (Job_cancelled ("job_1", "operator"))
;;

let () =
  Alcotest.run
    "Tool_job"
    [ ( "schema_hash"
      , [ Alcotest.test_case "stable under key reordering" `Quick test_schema_hash_is_stable ] )
    ; ( "make"
      , [ Alcotest.test_case "reads catalog metadata" `Quick test_make_reads_tool_metadata ] )
    ; ( "roundtrip"
      , [ Alcotest.test_case "policy verdict" `Quick test_policy_verdict_roundtrip
        ; Alcotest.test_case "job envelope" `Quick test_job_roundtrip
        ; Alcotest.test_case
            "job accepts missing option fields"
            `Quick
            test_job_roundtrip_accepts_missing_option_fields
        ; Alcotest.test_case "events" `Quick test_event_roundtrip
        ; Alcotest.test_case
            "event accepts missing option fields"
            `Quick
            test_event_batch_created_accepts_missing_option_fields
        ] )
    ; ( "resource_keys"
      , [ Alcotest.test_case "inference for known patterns" `Quick test_resource_key_inference ] )
    ; ( "event_helpers"
      , [ Alcotest.test_case "batch id helper is explicit" `Quick test_event_batch_id_exhaustive_helpers ]
      )
    ]
;;
