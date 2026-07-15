(** Explicit keeper memory writes use a direct, typed persistence path. *)

module Runtime = Masc.Keeper_tool_memory_runtime
module Bank = Masc.Keeper_memory_bank
module Work_request = Masc.Keeper_memory_work_request
module Work_store = Masc.Keeper_memory_work_store
module Work_drain = Masc.Keeper_memory_work_drain

let make_args ~kind ~title ~content =
  `Assoc
    [ "kind", `String kind
    ; "title", `String title
    ; "content", `String content
    ]
;;

let error_label = Runtime.memory_write_error_kind_to_string

let assert_invalid ~expected = function
  | Runtime.Memory_write_invalid { error_kind; _ } ->
    Alcotest.(check string) "error kind" expected (error_label error_kind)
  | Runtime.Memory_write_ok _ ->
    Alcotest.failf "expected invalid memory write: %s" expected
;;

let assert_ok ~kind ~body = function
  | Runtime.Memory_write_ok valid ->
    Alcotest.(check string)
      "kind"
      kind
      (Bank.memory_kind_to_wire valid.kind);
    Alcotest.(check string) "body" body valid.body
  | Runtime.Memory_write_invalid { error_kind; _ } ->
    Alcotest.failf "unexpected validation error: %s" (error_label error_kind)
;;

let rec remove_tree path =
  if Sys.file_exists path
  then if Sys.is_directory path
  then (
    Sys.readdir path
    |> Array.iter (fun name -> remove_tree (Filename.concat path name));
    Unix.rmdir path)
  else Sys.remove path
;;

let with_temp_dir f =
  let dir = Filename.temp_file "keeper-memory-write-" ".tmp" in
  Sys.remove dir;
  Unix.mkdir dir 0o700;
  Fun.protect ~finally:(fun () -> remove_tree dir) (fun () -> f dir)
;;

let make_meta name =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [ "name", `String name
        ; "trace_id", `String ("trace-" ^ name)
        ])
  with
  | Error error -> Alcotest.fail ("meta fixture failed: " ^ error)
  | Ok meta ->
    let usage = { meta.runtime.usage with total_turns = 7 } in
    { meta with runtime = { meta.runtime with usage } }
;;

let json_field key = function
  | `Assoc fields ->
    (match List.assoc_opt key fields with
     | Some value -> value
     | None -> Alcotest.failf "missing JSON field: %s" key)
  | _ -> Alcotest.fail "expected JSON object"
;;

let string_field key json =
  match json_field key json with
  | `String value -> value
  | _ -> Alcotest.failf "expected string field: %s" key
;;

let int_field key json =
  match json_field key json with
  | `Int value -> value
  | _ -> Alcotest.failf "expected int field: %s" key
;;

let only_jsonl_row path =
  let rows =
    Fs_compat.load_file path
    |> String.split_on_char '\n'
    |> List.filter (fun line -> String.trim line <> "")
  in
  match rows with
  | [ row ] -> Yojson.Safe.from_string row
  | _ -> Alcotest.failf "expected one memory row, got %d" (List.length rows)
;;

let test_validation_taxonomy () =
  Runtime.validate_memory_write_args
    (make_args ~kind:"bogus" ~title:"" ~content:"body")
  |> assert_invalid ~expected:"invalid_memory_kind";
  Runtime.validate_memory_write_args
    (make_args ~kind:"next" ~title:"" ~content:"body")
  |> assert_invalid ~expected:"invalid_memory_kind";
  Runtime.validate_memory_write_args
    (make_args ~kind:"constraints" ~title:"" ~content:"body")
  |> assert_invalid ~expected:"invalid_memory_kind";
  Runtime.validate_memory_write_args
    (make_args ~kind:"GOAL" ~title:"" ~content:"body")
  |> assert_invalid ~expected:"invalid_memory_kind";
  Runtime.validate_memory_write_args
    (make_args ~kind:" goal " ~title:"" ~content:"body")
  |> assert_invalid ~expected:"invalid_memory_kind";
  Runtime.validate_memory_write_args
    (make_args ~kind:"long_term" ~title:"" ~content:"body")
  |> assert_invalid ~expected:"long_term_via_explicit_write_not_yet_supported";
  Runtime.validate_memory_write_args
    (make_args ~kind:"goal" ~title:"" ~content:"")
  |> assert_invalid ~expected:"content_empty";
  Runtime.validate_memory_write_args
    (make_args ~kind:"goal" ~title:(String.make 121 'x') ~content:"body")
  |> assert_invalid ~expected:"title_too_long";
  Runtime.validate_memory_write_args
    (make_args ~kind:"goal" ~title:"" ~content:"none")
  |> assert_invalid ~expected:"content_rejected"
;;

let test_valid_body_has_no_intermediate_projection () =
  Runtime.validate_memory_write_args
    (make_args ~kind:"decision" ~title:"hook" ~content:"body text")
  |> assert_ok ~kind:"decision" ~body:"**hook** body text";
  Runtime.validate_memory_write_args
    (make_args ~kind:"goal" ~title:"" ~content:"plain body")
  |> assert_ok ~kind:"goal" ~body:"plain body"
;;

let test_bank_rejects_nonwritable_kind () =
  with_temp_dir
  @@ fun base_path ->
  let config = Masc.Workspace.default_config base_path in
  let meta = make_meta "invalid-bank-write" in
  (match
     Bank.append_explicit_memory_note
       config
       meta
       ~turn:7
       ~kind:Bank.Long_term
       ~text:"reserved kind"
   with
   | Error (Bank.Explicit_memory_kind_not_writable Bank.Long_term) -> ()
   | _ -> Alcotest.fail "nonwritable kind must be rejected explicitly");
  match
    Bank.append_explicit_memory_note
      config
      meta
      ~turn:7
      ~kind:Bank.Goal
      ~text:"none"
  with
  | Error Bank.Rejected_explicit_memory_text -> ()
  | _ -> Alcotest.fail "filtered content must return a typed rejection"
;;

let test_tool_write_persists_typed_provenance () =
  with_temp_dir
  @@ fun base_path ->
  let config = Masc.Workspace.default_config base_path in
  let meta = make_meta "typed-provenance" in
  let response =
    Runtime.keeper_memory_write_json
      ~config
      ~meta
      ~args:(make_args ~kind:"decision" ~title:"choice" ~content:"Use typed rows")
    |> Yojson.Safe.from_string
  in
  Alcotest.(check bool) "write succeeds" true
    (match json_field "ok" response with `Bool value -> value | _ -> false);
  Alcotest.(check int) "one row" 1 (int_field "rows_written" response);
  let path = Masc.Keeper_types_support.keeper_memory_bank_path config meta.name in
  let row = only_jsonl_row path in
  Alcotest.(check string)
    "typed source"
    "explicit_memory_write"
    (string_field "source" row);
  Alcotest.(check string) "kind" "decision" (string_field "kind" row);
  Alcotest.(check string) "horizon" "mid_term" (string_field "horizon" row);
  Alcotest.(check int) "turn comes from runtime usage SSOT" 7 (int_field "turn" row);
  Alcotest.(check string)
    "body"
    "**choice** Use typed rows"
    (string_field "text" row)
;;

let test_source_round_trip () =
  let source = Bank.Explicit_memory_write in
  let wire = Bank.memory_row_source_to_string source in
  Alcotest.(check string) "wire" "explicit_memory_write" wire;
  Alcotest.(check bool)
    "round trip"
    true
    (Bank.memory_row_source_of_string wire = source)
;;

let test_memory_work_request_strict_round_trip () =
  let meta = make_meta "durable-memory-work" in
  let librarian_message =
    let message =
      Agent_sdk.Types.text_message Agent_sdk.Types.User "remember this"
    in
    { message with metadata = [ "source", `String "memory-lane-test" ] }
  in
  let request =
    Work_request.make
      ~keeper_name:meta.name
      ~generation:meta.runtime.generation
      ~turn:8
      ~runtime_id:"runtime.memory"
      ~meta
      ~tool_results:[ `Assoc [ "kind", `String "typed-tool-result" ] ]
      ~librarian_messages:[ librarian_message ]
      ~deliberation_execution:None
    |> Result.get_ok
  in
  let encoded = Work_request.to_json request in
  let decoded = Work_request.of_json encoded |> Result.get_ok in
  Alcotest.(check string)
    "content-derived identity round trips"
    (Work_request.request_id request)
    (Work_request.request_id decoded);
  Alcotest.(check string) "keeper identity" meta.name (Work_request.keeper_name decoded);
  let decoded_messages = Work_request.librarian_messages decoded in
  Alcotest.(check int) "one message" 1 (List.length decoded_messages);
  Alcotest.(check int)
    "message metadata preserved"
    1
    (List.length (List.hd decoded_messages).metadata);
  let tampered =
    match encoded with
    | `Assoc fields ->
      `Assoc
        (List.map
           (fun (name, value) ->
              if String.equal name "request_id"
              then name, `String "tampered"
              else name, value)
           fields)
    | _ -> Alcotest.fail "request encoding must be an object"
  in
  match Work_request.of_json tampered with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "tampered request identity was accepted"
;;

let test_memory_work_store_exact_fifo () =
  with_temp_dir (fun base_path ->
    let meta = make_meta "durable-memory-fifo" in
    let make_request turn =
      Work_request.make
        ~keeper_name:meta.name
        ~generation:meta.runtime.generation
        ~turn
        ~runtime_id:(Printf.sprintf "runtime.memory.%d" turn)
        ~meta
        ~tool_results:[ `Assoc [ "turn", `Int turn ] ]
        ~librarian_messages:[]
        ~deliberation_execution:None
      |> Result.get_ok
    in
    let first = make_request 1 in
    let second = make_request 2 in
    let enqueue request =
      match Work_store.enqueue ~base_path request with
      | Ok outcome -> outcome
      | Error error -> Alcotest.fail (Work_store.error_to_string error)
    in
    Alcotest.(check bool)
      "first admitted"
      true
      (enqueue first = Work_store.Enqueued);
    Alcotest.(check bool)
      "second admitted"
      true
      (enqueue second = Work_store.Enqueued);
    Alcotest.(check bool)
      "duplicate is exact no-op"
      true
      (enqueue first = Work_store.Already_present);
    let pending =
      Work_store.pending ~base_path ~keeper_name:meta.name
      |> Result.map_error Work_store.error_to_string
      |> Result.get_ok
    in
    Alcotest.(check (list string))
      "durable FIFO order"
      [ Work_request.request_id first; Work_request.request_id second ]
      (List.map Work_request.request_id pending);
    let path =
      Work_store.queue_path ~base_path ~keeper_name:meta.name
      |> Result.map_error Work_store.error_to_string
      |> Result.get_ok
    in
    let json = Safe_ops.read_json_file_safe path |> Result.get_ok in
    let duplicate_json =
      match json with
      | `Assoc fields ->
        `Assoc
          (List.map
             (fun (name, value) ->
                match name, value with
                | "pending", `List (first :: _ as pending) ->
                  name, `List (pending @ [ first ])
                | _ -> name, value)
             fields)
      | _ -> Alcotest.fail "queue encoding must be an object"
    in
    Yojson.Safe.to_file path duplicate_json;
    match Work_store.pending ~base_path ~keeper_name:meta.name with
    | Error (Work_store.Decode_failed _) -> ()
    | Error error -> Alcotest.fail (Work_store.error_to_string error)
    | Ok _ -> Alcotest.fail "duplicate durable request was accepted")
;;

let test_memory_work_store_claim_settle_recovery () =
  with_temp_dir (fun base_path ->
    let meta = make_meta "durable-memory-claim" in
    let make_request turn =
      Work_request.make
        ~keeper_name:meta.name
        ~generation:meta.runtime.generation
        ~turn
        ~runtime_id:(Printf.sprintf "runtime.claim.%d" turn)
        ~meta
        ~tool_results:[ `Assoc [ "turn", `Int turn ] ]
        ~librarian_messages:[]
        ~deliberation_execution:None
      |> Result.get_ok
    in
    let first, second, third = make_request 1, make_request 2, make_request 3 in
    List.iter
      (fun request ->
         Work_store.enqueue ~base_path request
         |> Result.map_error Work_store.error_to_string
         |> Result.get_ok
         |> ignore)
      [ first; second; third ];
    let claim () =
      Work_store.claim_next ~base_path ~keeper_name:meta.name
      |> Result.map_error Work_store.error_to_string
      |> Result.get_ok
    in
    (match claim () with
     | Work_store.Claimed request ->
       Alcotest.(check string)
         "first claimed"
         (Work_request.request_id first)
         (Work_request.request_id request)
     | Work_store.Queue_empty | Work_store.Claim_busy _ ->
       Alcotest.fail "first request was not claimed");
    Alcotest.(check bool)
      "second claim cannot duplicate in-flight work"
      true
      (claim () = Work_store.Claim_busy (Work_request.request_id first));
    let recovered =
      Work_store.recover_in_flight ~base_path ~keeper_name:meta.name
      |> Result.map_error Work_store.error_to_string
      |> Result.get_ok
      |> Option.get
    in
    Alcotest.(check string)
      "restart recovery keeps exact claim"
      (Work_request.request_id first)
      (Work_request.request_id recovered);
    let settle request outcome =
      Work_store.settle
        ~base_path
        ~keeper_name:meta.name
        ~request_id:(Work_request.request_id request)
        outcome
      |> Result.map_error Work_store.error_to_string
      |> Result.get_ok
    in
    Alcotest.(check bool)
      "first settled"
      true
      (settle first Work_store.Completed = Work_store.Settled);
    Alcotest.(check bool)
      "settlement replay is idempotent"
      true
      (settle first Work_store.Completed = Work_store.Already_settled);
    (match
       Work_store.settle
         ~base_path
         ~keeper_name:meta.name
         ~request_id:(Work_request.request_id first)
         (Work_store.Failed "conflicting replay")
     with
     | Error (Work_store.Settlement_conflict _) -> ()
     | Error error -> Alcotest.fail (Work_store.error_to_string error)
     | Ok _ -> Alcotest.fail "conflicting settlement was accepted");
    (match claim () with
     | Work_store.Claimed request ->
       Alcotest.(check string)
         "second claimed"
         (Work_request.request_id second)
         (Work_request.request_id request)
     | Work_store.Queue_empty | Work_store.Claim_busy _ ->
       Alcotest.fail "second request was not claimed");
    ignore (settle second (Work_store.Failed "provider unavailable") : Work_store.settle_result);
    match claim () with
    | Work_store.Claimed request ->
      Alcotest.(check string)
        "failed unit does not block the next unit"
        (Work_request.request_id third)
        (Work_request.request_id request)
    | Work_store.Queue_empty | Work_store.Claim_busy _ ->
      Alcotest.fail "third request did not progress after failure")
;;

let test_memory_work_drain_exact_settlement () =
  with_temp_dir (fun base_path ->
    let meta = make_meta "durable-memory-drain" in
    let make_request turn =
      Work_request.make
        ~keeper_name:meta.name
        ~generation:meta.runtime.generation
        ~turn
        ~runtime_id:(Printf.sprintf "runtime.drain.%d" turn)
        ~meta
        ~tool_results:[]
        ~librarian_messages:[]
        ~deliberation_execution:None
      |> Result.get_ok
    in
    let first, second = make_request 1, make_request 2 in
    List.iter
      (fun request ->
         Work_store.enqueue ~base_path request
         |> Result.map_error Work_store.error_to_string
         |> Result.get_ok
         |> ignore)
      [ first; second ];
    let observed = ref [] in
    let execute request =
      observed := Work_request.request_id request :: !observed;
      if Work_request.turn request = 2 then Error "provider unavailable" else Ok ()
    in
    let report =
      Work_drain.drain ~base_path ~keeper_name:meta.name ~execute
      |> Result.map_error Work_drain.error_to_string
      |> Result.get_ok
    in
    Alcotest.(check (list string))
      "exact execution order"
      (List.map Work_request.request_id [ first; second ])
      (List.rev !observed);
    Alcotest.(check int) "completed" 1 report.completed;
    Alcotest.(check int) "failed" 1 report.failed;
    let terminal =
      Work_store.terminal ~base_path ~keeper_name:meta.name
      |> Result.map_error Work_store.error_to_string
      |> Result.get_ok
    in
    (match List.map (fun item -> item.Work_store.outcome) terminal with
     | [ Work_store.Completed; Work_store.Failed "provider unavailable" ] -> ()
     | _ -> Alcotest.fail "terminal outcome or order mismatch");
    Alcotest.(check int) "both outcomes durable" 2 (List.length terminal))
;;

let () =
  Alcotest.run
    "keeper_memory_write"
    [ ( "validation"
      , [ Alcotest.test_case "typed validation failures" `Quick test_validation_taxonomy
        ; Alcotest.test_case
            "valid input remains a direct kind/body pair"
            `Quick
            test_valid_body_has_no_intermediate_projection
        ] )
    ; ( "persistence"
      , [ Alcotest.test_case
            "bank rejects nonwritable kinds"
            `Quick
            test_bank_rejects_nonwritable_kind
        ; Alcotest.test_case
            "tool write stores typed provenance"
            `Quick
            test_tool_write_persists_typed_provenance
        ; Alcotest.test_case "source round trips" `Quick test_source_round_trip
        ; Alcotest.test_case
            "durable work request strict round trip"
            `Quick
            test_memory_work_request_strict_round_trip
        ; Alcotest.test_case
            "durable work store exact FIFO"
            `Quick
            test_memory_work_store_exact_fifo
        ; Alcotest.test_case
            "durable work store claim settle recovery"
            `Quick
            test_memory_work_store_claim_settle_recovery
        ; Alcotest.test_case
            "durable work drain exact settlement"
            `Quick
            test_memory_work_drain_exact_settlement
        ] )
    ]
;;
