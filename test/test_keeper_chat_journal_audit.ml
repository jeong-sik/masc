(* RFC-0412 stage 2 — dual-write consistency auditor: every verdict class of
   the pure comparison core, the IO shell over a real journal file and real
   keeper_chat_store rows, and the sweep's liveness / audited-once /
   canonical-stem gating. *)

module Audit = Masc.Keeper_chat_journal_audit
module E = Masc.Keeper_chat_events
module L = Masc.Keeper_chat_event_log
module Store = Masc.Keeper_chat_store
module Outcome = Masc.Keeper_turn_outcome
module Delivery = Keeper_chat_delivery_identity

let verdict = Alcotest.testable Audit.pp_verdict Audit.equal_verdict

let turn_ref = Ids.Turn_ref.make ~trace_id:"trace-1" ~absolute_turn:3
let execution_id = Ids.Execution_id.of_string "exec-1"

let occurrence : E.tool_stream_occurrence =
  { stream_scope = 0; provider_message_id = None; block_index = 0 }

let delivery_key_of operation_id =
  match Delivery.Request_id.of_string operation_id with
  | Ok request_id -> Delivery.Operation request_id
  | Error detail -> Alcotest.fail detail

let journaled ~seq ~ts event : L.journaled_event = { seq; ts; event }

(* The canonical successful turn: run_started -> deltas -> tool result ->
   reply_details -> text_message_end -> run_finished. *)
let match_events =
  [ E.Run_started { run_id = "run-1"; thread_id = "thread-1" }
  ; E.Text_message_start { message_id = "msg-1"; role = E.Assistant }
  ; E.Text_delta "hello"
  ; E.Tool_result_ready
      { occurrence; tool_call_id = Some "tc-1"; execution_id }
  ; E.Reply_details
      { reply = "done"; turn_outcome = Outcome.Visible_reply; turn_ref }
  ; E.Text_message_end
  ; E.Run_finished { run_id = "run-1" }
  ]

let match_entries =
  List.mapi (fun i event -> journaled ~seq:i ~ts:(100.0 +. (Float.of_int i *. 0.1)) event) match_events

let chat_message
    ?(id = "m-1")
    ?(role = Store.Role.Assistant)
    ?(content = "")
    ?(ts = 100.2)
    ?execution_id
    ?(kind = Store.Row_kind.Utterance)
    ?turn_ref
    ?stream_lifecycle
    ?delivery_provenance
    ()
  : Store.chat_message
  =
  { id
  ; role
  ; content
  ; ts
  ; attachments = None
  ; tool_call_id = None
  ; execution_id
  ; tool_call_name = None
  ; surface = None
  ; conversation_id = None
  ; external_message_id = None
  ; workspace_id = None
  ; speaker = None
  ; audio = None
  ; blocks = None
  ; mentions = []
  ; kind
  ; turn_ref
  ; stream_lifecycle
  ; approval_lifecycle = None
  ; delivery_provenance
  }

let ok_lifecycle =
  [ Store.Run_started
  ; Store.Text_message_start
  ; Store.Text_message_end
  ; Store.Run_finished
  ]

let user_row ~delivery_key =
  chat_message
    ~id:"m-user"
    ~role:Store.Role.User
    ~content:"hi"
    ~delivery_provenance:
      { Delivery.delivery_key = delivery_key
      ; transcript_slot = Delivery.Accepted_user
      }
    ()

let assistant_row ~delivery_key =
  chat_message
    ~id:"m-assistant"
    ~content:"done"
    ~turn_ref
    ~stream_lifecycle:ok_lifecycle
    ~delivery_provenance:
      { Delivery.delivery_key = delivery_key
      ; transcript_slot = Delivery.Terminal_assistant
      }
    ()

let tool_row ~delivery_key =
  chat_message
    ~id:"m-tool"
    ~role:Store.Role.Tool
    ~execution_id
    ~delivery_provenance:
      { Delivery.delivery_key = delivery_key
      ; transcript_slot = Delivery.Tool_call { execution_id; ordinal = 0 }
      }
    ()

let match_rows =
  let delivery_key = delivery_key_of "op-1" in
  [ user_row ~delivery_key; assistant_row ~delivery_key; tool_row ~delivery_key ]

let test_match () =
  Alcotest.(check verdict) "match" Audit.Match (Audit.compare match_entries match_rows)

let test_terminal_outcome_mismatch () =
  let rows =
    match match_rows with
    | [ user; assistant; tool ] ->
      [ user
      ; { assistant with Store.stream_lifecycle = Some [ Store.Run_started; Store.Run_error ] }
      ; tool
      ]
    | _ -> Alcotest.fail "match_rows shape"
  in
  Alcotest.(check verdict)
    "terminal outcome"
    (Audit.Mismatch [ Audit.Terminal_outcome ])
    (Audit.compare match_entries rows)

let test_assistant_text_mismatch () =
  let rows =
    match match_rows with
    | [ user; assistant; tool ] -> [ user; { assistant with Store.content = "other" }; tool ]
    | _ -> Alcotest.fail "match_rows shape"
  in
  Alcotest.(check verdict)
    "assistant text"
    (Audit.Mismatch [ Audit.Assistant_text ])
    (Audit.compare match_entries rows)

let test_tool_row_missing () =
  let rows =
    match match_rows with
    | [ user; assistant; _ ] -> [ user; assistant ]
    | _ -> Alcotest.fail "match_rows shape"
  in
  Alcotest.(check verdict)
    "tool row missing"
    (Audit.Mismatch [ Audit.Tool_rows ])
    (Audit.compare match_entries rows)

let test_tool_rows_duplicate_execution_id () =
  (* Two store tool rows carrying the same execution_id: subset-both-ways
     passed this silently; the sorted-multiset equality must not. *)
  let rows =
    match match_rows with
    | [ user; assistant; tool ] ->
      [ user; assistant; tool; { tool with Store.id = "m-tool-2" } ]
    | _ -> Alcotest.fail "match_rows shape"
  in
  Alcotest.(check verdict)
    "duplicate execution_id on the store side"
    (Audit.Mismatch [ Audit.Tool_rows ])
    (Audit.compare match_entries rows)

let test_seq_gap () =
  let entries =
    [ journaled ~seq:0 ~ts:100.0 (E.Run_started { run_id = "run-1"; thread_id = "t" })
    ; journaled ~seq:1 ~ts:100.1 (E.Text_delta "hello")
    ; journaled ~seq:3 ~ts:100.3 (E.Run_finished { run_id = "run-1" })
    ]
  in
  (* No [Reply_details] and no [Tool_result_ready] in the journal; the rows
     carry no tool row either, so only the gap can fire. *)
  let rows =
    match match_rows with
    | [ user; assistant; _ ] -> [ user; assistant ]
    | _ -> Alcotest.fail "match_rows shape"
  in
  Alcotest.(check verdict)
    "seq gap"
    (Audit.Mismatch [ Audit.Seq_gap ])
    (Audit.compare entries rows)

let test_truncated () =
  let entries =
    [ journaled ~seq:0 ~ts:100.0 (E.Run_started { run_id = "run-1"; thread_id = "t" })
    ; journaled ~seq:1 ~ts:100.1 (E.Text_delta "half-finis")
    ]
  in
  Alcotest.(check verdict)
    "truncated regardless of rows"
    Audit.Journal_truncated
    (Audit.compare entries match_rows)

let test_missing_terminal_row () =
  Alcotest.(check verdict)
    "terminal events, no joined rows"
    (Audit.Mismatch [ Audit.Missing_terminal_row ])
    (Audit.compare match_entries [])

let test_surface_post_exclusion () =
  let surface_post_row =
    (* keeper_tool_in_process_runtime mid-turn post: no turn_ref, no
       provenance, ts inside the journal window. Never a mismatch. *)
    chat_message ~id:"m-surface" ~content:"posted to the surface" ~ts:100.25 ()
  in
  Alcotest.(check bool)
    "is_surface_post_row accepts the key-less in-window row"
    true
    (Audit.is_surface_post_row ~first_ts:100.0 ~last_ts:100.6 surface_post_row);
  Alcotest.(check bool)
    "is_surface_post_row rejects a joined row"
    false
    (Audit.is_surface_post_row
       ~first_ts:100.0
       ~last_ts:100.6
       (assistant_row ~delivery_key:(delivery_key_of "op-1")));
  Alcotest.(check verdict)
    "surface-post row does not break the match"
    Audit.Match
    (Audit.compare match_entries (match_rows @ [ surface_post_row ]))

(* --- temp-dir idiom (same as test_keeper_chat_event_log.ml) --- *)

let temp_base_path prefix =
  Filename.concat
    (Filename.get_temp_dir_name ())
    (Printf.sprintf "%s-%d-%d" prefix (Unix.getpid ()) (Random.bits ()))

let rec remove_tree path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then begin
      Sys.readdir path
      |> Array.iter (fun name -> remove_tree (Filename.concat path name));
      Unix.rmdir path
    end
    else Sys.remove path

let write_journal ~base_dir ~keeper_name ~operation_id events =
  let journal = L.open_journal ~base_dir ~keeper_name ~operation_id () in
  List.iteri
    (fun seq event ->
       L.append journal ~seq ~ts:(100.0 +. (Float.of_int seq *. 0.1)) event)
    events

let write_store_rows ~base_dir ~keeper_name ~delivery_key =
  let require = function
    | Ok _ -> ()
    | Error detail -> Alcotest.fail detail
  in
  require
    (Store.append_user_message_once ~base_dir ~keeper_name ~delivery_key ~content:"hi" ());
  require
    (Store.append_assistant_message_once
       ~base_dir
       ~keeper_name
       ~delivery_key
       ~content:"done"
       ~turn_ref
       ~stream_lifecycle:ok_lifecycle
       ());
  require
    (Store.append_tool_calls_once
       ~base_dir
       ~keeper_name
       ~delivery_key
       ~tool_calls:
         [ { Store.call_id = "tc-1"
           ; execution_id = Some execution_id
           ; call_name = "read_file"
           ; args = "{}"
           }
         ]
       ~turn_ref
       ())

let test_audit_operation_match () =
  let base_dir = temp_base_path "keeper-chat-journal-audit" in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_dir with _ -> ())
    (fun () ->
       let keeper_name = "audit-keeper" in
       let operation_id = "op-1" in
       write_journal ~base_dir ~keeper_name ~operation_id match_events;
       write_store_rows
         ~base_dir
         ~keeper_name
         ~delivery_key:(delivery_key_of operation_id);
       Alcotest.(check verdict)
         "journal and store agree"
         Audit.Match
         (Audit.audit_operation ~base_dir ~keeper_name ~operation_id))

let test_audit_operation_missing_journal () =
  let base_dir = temp_base_path "keeper-chat-journal-audit-missing" in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_dir with _ -> ())
    (fun () ->
       Alcotest.(check verdict)
         "fail-open append may never have created the file"
         Audit.Journal_missing
         (Audit.audit_operation ~base_dir ~keeper_name:"k" ~operation_id:"op-gone"))

let test_audit_operation_corrupt_journal () =
  let base_dir = temp_base_path "keeper-chat-journal-audit-corrupt" in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_dir with _ -> ())
    (fun () ->
       let path = L.journal_path ~base_dir ~keeper_name:"k" ~operation_id:"op-bad" in
       Fs_compat.mkdir_p (Filename.dirname path);
       let oc = open_out path in
       output_string oc "this is not json\n";
       close_out oc;
       match Audit.audit_operation ~base_dir ~keeper_name:"k" ~operation_id:"op-bad" with
       | Audit.Journal_corrupt _ -> ()
       | other ->
         Alcotest.failf "expected Journal_corrupt, got %s" (Audit.show_verdict other))

let test_audit_operation_store_unreadable () =
  let base_dir = temp_base_path "keeper-chat-journal-audit-store" in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_dir with _ -> ())
    (fun () ->
       let keeper_name = "store-keeper" in
       let operation_id = "op-store" in
       write_journal ~base_dir ~keeper_name ~operation_id match_events;
       let store_path = Store.chat_path ~base_dir ~keeper_name in
       Fs_compat.mkdir_p (Filename.dirname store_path);
       let oc = open_out store_path in
       output_string oc "{\"not\":\"a chat row\"}\n";
       close_out oc;
       (* [load_all] converts the EACCES read failure into []; the non-empty
          file on disk must surface as [Store_unreadable], not
          [Missing_terminal_row]. *)
       Unix.chmod store_path 0o000;
       Fun.protect
         ~finally:(fun () -> try Unix.chmod store_path 0o600 with _ -> ())
         (fun () ->
            match
              Audit.audit_operation ~base_dir ~keeper_name ~operation_id
            with
            | Audit.Store_unreadable _ -> ()
            | other ->
              Alcotest.failf
                "expected Store_unreadable, got %s"
                (Audit.show_verdict other)))

let test_journal_path_round_trips_operation_ids () =
  (* The sweep recovers operation_id from the journal filename stem; the ids
     the TUI and dashboard actually mint survive sanitization unchanged. *)
  List.iter
    (fun operation_id ->
       let stem =
         Filename.remove_extension
           (Filename.basename
              (L.journal_path ~base_dir:"/tmp/base" ~keeper_name:"k" ~operation_id))
       in
       Alcotest.(check string) "operation_id round-trips" operation_id stem)
    [ "tui-0190f9e2-3b4a-7c2d-9e1f-0a1b2c3d4e5f"
    ; "kmsg-3f8a1c2e9b0d4e7fa5b6c7d8e9f0a1b2"
    ]

let sorted_dir_entries dir = Sys.readdir dir |> Array.to_list |> List.sort String.compare

(* No terminal event: the shape of a turn still streaming (or already
   crashed). The registry's answer is what separates the two. *)
let in_flight_events =
  [ E.Run_started { run_id = "run-1"; thread_id = "thread-1" }
  ; E.Text_delta "half-finis"
  ]

let settled ~keeper_name:_ ~operation_id:_ = Audit.Turn_settled
let running ~keeper_name:_ ~operation_id:_ = Audit.Turn_running

let sweep ?(audited = Audit.Audited.empty) ~liveness base_dir =
  Audit.sweep ~base_dir ~lookback_sec:3600. ~liveness ~audited ()

let test_sweep_reads_by_registry_liveness_not_file_age () =
  let base_dir = temp_base_path "keeper-chat-journal-audit-liveness" in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_dir with _ -> ())
    (fun () ->
       let keeper_name = "sweep-keeper" in
       let operation_id = "op-live" in
       write_journal ~base_dir ~keeper_name ~operation_id in_flight_events;
       (* Fresh on disk and, per the registry, still running: left alone. *)
       let results, audited = sweep ~liveness:running base_dir in
       Alcotest.(check int) "a running turn's journal is not read" 0 (List.length results);
       Alcotest.(check bool) "nor marked audited" true (Audit.Audited.is_empty audited);
       (* Same fresh file, registry says the turn ended: the missing terminal
          event is a truncated journal, whatever the file's age. *)
       (match sweep ~liveness:settled base_dir with
        | [ (keeper, op, Audit.Journal_truncated) ], audited ->
          Alcotest.(check string) "keeper" keeper_name keeper;
          Alcotest.(check string) "operation id" operation_id op;
          Alcotest.(check bool)
            "the settled operation is marked audited"
            true
            (Audit.Audited.mem (keeper_name, operation_id) audited)
        | other, _ ->
          Alcotest.failf
            "expected one Journal_truncated, got %d verdicts"
            (List.length other)))

let test_sweep_audits_each_operation_once () =
  let base_dir = temp_base_path "keeper-chat-journal-audit-once" in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_dir with _ -> ())
    (fun () ->
       let keeper_name = "once-keeper" in
       let operation_id = "op-once" in
       write_journal ~base_dir ~keeper_name ~operation_id match_events;
       write_store_rows ~base_dir ~keeper_name ~delivery_key:(delivery_key_of operation_id);
       let first, audited = sweep ~liveness:settled base_dir in
       Alcotest.(check int) "first pass reports the operation" 1 (List.length first);
       (match first with
        | [ (_, _, Audit.Match) ] -> ()
        | _ -> Alcotest.fail "expected Match on the first pass");
       let second, audited = sweep ~audited ~liveness:settled base_dir in
       Alcotest.(check int) "second pass with the same set reports nothing" 0 (List.length second);
       Alcotest.(check bool)
         "the set carries the operation forward"
         true
         (Audit.Audited.mem (keeper_name, operation_id) audited))

let test_sweep_reports_unanswered_registry_and_retries () =
  let base_dir = temp_base_path "keeper-chat-journal-audit-unanswered" in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_dir with _ -> ())
    (fun () ->
       let keeper_name = "fenced-keeper" in
       let operation_id = "op-fenced" in
       write_journal ~base_dir ~keeper_name ~operation_id match_events;
       let unanswered ~keeper_name:_ ~operation_id:_ =
         Audit.Registry_unanswered "owner fenced"
       in
       (match sweep ~liveness:unanswered base_dir with
        | [ (_, _, Audit.Liveness_unknown "owner fenced") ], audited ->
          Alcotest.(check bool)
            "an unanswered operation is not marked audited"
            true
            (Audit.Audited.is_empty audited)
        | other, _ ->
          Alcotest.failf "expected one Liveness_unknown, got %d verdicts" (List.length other));
       (* Once the registry answers, the same file is audited. *)
       match sweep ~liveness:settled base_dir with
       | [ (_, _, verdict) ], _ ->
         Alcotest.(check bool)
           "a later pass reads the journal"
           true
           (match verdict with
            | Audit.Liveness_unknown _ -> false
            | Audit.Match | Audit.Mismatch _ | Audit.Journal_missing
            | Audit.Journal_unreadable _ | Audit.Journal_truncated
            | Audit.Journal_corrupt _ | Audit.Store_unreadable _ -> true)
       | other, _ ->
         Alcotest.failf "expected one verdict, got %d" (List.length other))

let test_sweep_reports_unreadable_journal () =
  let base_dir = temp_base_path "keeper-chat-journal-audit-unreadable" in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_dir with _ -> ())
    (fun () ->
       let keeper_name = "eacces-keeper" in
       let operation_id = "op-eacces" in
       write_journal ~base_dir ~keeper_name ~operation_id match_events;
       let path = L.journal_path ~base_dir ~keeper_name ~operation_id in
       (* root reads a 0o000 file, so the verdict cannot be observed there. *)
       if Unix.geteuid () <> 0
       then begin
         Unix.chmod path 0o000;
         Fun.protect
           ~finally:(fun () -> try Unix.chmod path 0o600 with _ -> ())
           (fun () ->
              (match Audit.audit_operation ~base_dir ~keeper_name ~operation_id with
               | Audit.Journal_unreadable _ -> ()
               | other ->
                 Alcotest.failf
                   "audit_operation: expected Journal_unreadable, got %s"
                   (Audit.show_verdict other));
              match sweep ~liveness:settled base_dir with
              | [ (_, op, Audit.Journal_unreadable _) ], _ ->
                Alcotest.(check string) "sweep names the operation" operation_id op
              | other, _ ->
                Alcotest.failf
                  "sweep: expected one Journal_unreadable, got %d verdicts"
                  (List.length other))
       end)

let test_sweep_skips_non_canonical_stem () =
  let base_dir = temp_base_path "keeper-chat-journal-audit-noncanonical" in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_dir with _ -> ())
    (fun () ->
       let keeper_name = "nc-keeper" in
       let dir =
         Filename.dirname
           (L.journal_path ~base_dir ~keeper_name ~operation_id:"placeholder")
       in
       Fs_compat.mkdir_p dir;
       let path = Filename.concat dir "Op-ABC.jsonl" in
       let oc = open_out path in
       List.iteri
         (fun seq event ->
            output_string
              oc
              (L.journaled_event_to_string
                 (journaled ~seq ~ts:(100.0 +. (Float.of_int seq *. 0.1)) event));
            output_char oc '\n')
         match_events;
       close_out oc;
       let before = sorted_dir_entries dir in
       (* Settled per the registry: only the non-canonical stem can keep it
          out of the verdicts. *)
       let results, _ = sweep ~liveness:settled base_dir in
       Alcotest.(check int) "a non-canonical stem is outside the audit" 0 (List.length results);
       Alcotest.(check (list string))
         "the sweep created no junk directory or file"
         before
         (sorted_dir_entries dir))

let () =
  Alcotest.run
    "keeper_chat_journal_audit"
    [ ( "compare"
      , [ Alcotest.test_case "match" `Quick test_match
        ; Alcotest.test_case
            "terminal outcome mismatch"
            `Quick
            test_terminal_outcome_mismatch
        ; Alcotest.test_case
            "assistant text mismatch"
            `Quick
            test_assistant_text_mismatch
        ; Alcotest.test_case "tool row missing" `Quick test_tool_row_missing
        ; Alcotest.test_case
            "duplicate execution_id is a tool-rows mismatch"
            `Quick
            test_tool_rows_duplicate_execution_id
        ; Alcotest.test_case "seq gap" `Quick test_seq_gap
        ; Alcotest.test_case "truncated journal" `Quick test_truncated
        ; Alcotest.test_case "missing terminal row" `Quick test_missing_terminal_row
        ; Alcotest.test_case
            "surface-post rows are an exclusion class"
            `Quick
            test_surface_post_exclusion
        ] )
    ; ( "io"
      , [ Alcotest.test_case
            "audit_operation over a real journal and store"
            `Quick
            test_audit_operation_match
        ; Alcotest.test_case
            "missing journal is Journal_missing"
            `Quick
            test_audit_operation_missing_journal
        ; Alcotest.test_case
            "corrupt journal is Journal_corrupt"
            `Quick
            test_audit_operation_corrupt_journal
        ; Alcotest.test_case
            "unreadable store is Store_unreadable"
            `Quick
            test_audit_operation_store_unreadable
        ; Alcotest.test_case
            "operation ids round-trip through journal_path"
            `Quick
            test_journal_path_round_trips_operation_ids
        ] )
    ; ( "sweep"
      , [ Alcotest.test_case
            "reads by registry liveness, not file age"
            `Quick
            test_sweep_reads_by_registry_liveness_not_file_age
        ; Alcotest.test_case
            "audits each operation once"
            `Quick
            test_sweep_audits_each_operation_once
        ; Alcotest.test_case
            "reports an unanswered registry and retries"
            `Quick
            test_sweep_reports_unanswered_registry_and_retries
        ; Alcotest.test_case
            "reports an unreadable journal"
            `Quick
            test_sweep_reports_unreadable_journal
        ; Alcotest.test_case
            "non-canonical stems are skipped without side effects"
            `Quick
            test_sweep_skips_non_canonical_stem
        ] )
    ]
