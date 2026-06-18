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

let test_resource_key_inference () =
  let check ~tool_name ~input ~expected =
    let actual = default_resource_keys_of_tool ~tool_name ~input_json:input in
    Alcotest.(check (list string)) (Printf.sprintf "%s resource keys" tool_name) expected actual
  in
  check
    ~tool_name:"masc_goal_transition"
    ~input:(`Assoc [ "goal_id", `String "goal_01J" ])
    ~expected:[ "goal:goal_01J" ];
  check
    ~tool_name:"masc_task_claim"
    ~input:(`Assoc [ "task_id", `String "task_01J" ])
    ~expected:[ "task:task_01J" ];
  check
    ~tool_name:"tool_edit_file"
    ~input:(`Assoc [ "path", `String "lib/foo.ml" ])
    ~expected:[ "file:lib/foo.ml" ];
  check
    ~tool_name:"tool_search_files"
    ~input:(`Assoc [ "path", `String "/repo" ])
    ~expected:[ "repo:/repo" ];
  check ~tool_name:"unknown_tool" ~input:(`Assoc []) ~expected:[]
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
        ; Alcotest.test_case "events" `Quick test_event_roundtrip
        ] )
    ; ( "resource_keys"
      , [ Alcotest.test_case "inference for known patterns" `Quick test_resource_key_inference ] )
    ]
;;
