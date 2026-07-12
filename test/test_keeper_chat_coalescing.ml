(* Durable Keeper chat receipt lifecycle regression suite. *)

open Masc

let failures = ref 0

let check name condition =
  if condition
  then Printf.printf "  ✓ %s\n%!" name
  else begin
    incr failures;
    Printf.printf "  ✗ %s\n%!" name
  end

let temp_dir prefix = Filename.temp_dir prefix ""

let rec rm_rf path =
  if Sys.file_exists path
  then if Sys.is_directory path
    then begin
      Sys.readdir path
      |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path
    end
    else Unix.unlink path

let with_base prefix body =
  let base_path = temp_dir prefix in
  Fun.protect
    ~finally:(fun () ->
      Keeper_chat_queue.For_testing.reset ();
      rm_rf base_path)
    (fun () -> body base_path)

let message ?(source = Keeper_chat_queue.Dashboard) ?(timestamp = 1.0)
    ?(user_blocks = []) ?(attachments = []) content =
  let transcript_context : Keeper_chat_queue.transcript_context option =
    match source with
    | Keeper_chat_queue.Dashboard -> None
    | Keeper_chat_queue.Discord { channel_id; user_id } ->
      Some
        { surface =
            Surface_ref.Discord
              { guild_id = None
              ; channel_id
              ; parent_channel_id = None
              ; thread_id = None
              }
        ; conversation_id = None
        ; external_message_id = None
        ; speaker =
            { Keeper_chat_store.speaker_id = Some user_id
            ; speaker_name = None
            ; speaker_authority = Keeper_chat_store.External
            }
        ; extra_mentions = []
        }
    | Keeper_chat_queue.Slack
        { channel_id; user_id; user_name; team_id; thread_ts } ->
      Some
        { surface = Surface_ref.Slack { team_id; channel_id; thread_ts }
        ; conversation_id = None
        ; external_message_id = None
        ; speaker =
            { Keeper_chat_store.speaker_id = Some user_id
            ; speaker_name = Some user_name
            ; speaker_authority = Keeper_chat_store.External
            }
        ; extra_mentions = []
        }
  in
  { Keeper_chat_queue.content
  ; user_blocks
  ; attachments
  ; timestamp
  ; source
  ; transcript_context
  ; transcript_ownership = Keeper_chat_queue.Queue_owned
  }

let attachment id =
  { Keeper_chat_store.id
  ; att_type = "file"
  ; name = id ^ ".txt"
  ; size = 1
  ; mime_type = "text/plain"
  ; data = "d"
  }

let image_block attachment_id =
  Keeper_multimodal_input.User_image
    { attachment_id
    ; name = attachment_id ^ ".png"
    ; mime_type = "image/png"
    ; size = None
    }

let workspace_config ?(cluster_name = "default") base_path =
  let config : Workspace.config = Workspace.default_config base_path in
  let backend_config =
    { config.backend_config with Backend_types.cluster_name = cluster_name }
  in
  { config with backend_config }

let configure_raw base_path =
  Keeper_chat_queue.configure_persistence
    ~config:(workspace_config base_path)

let configure base_path =
  let report = configure_raw base_path in
  check "persistence configure has no load errors" (report.load_errors = []);
  report

let enqueue_exn ~keeper_name message =
  match Keeper_chat_queue.enqueue ~keeper_name message with
  | Ok receipt -> receipt
  | Error error ->
    check
      ("enqueue succeeds: " ^ Keeper_chat_queue.mutation_error_to_string error)
      false;
    failwith "enqueue failed"

let lease_exn ~keeper_name =
  match Keeper_chat_queue.lease_batch ~keeper_name with
  | `Leased lease -> lease
  | `Empty ->
    check "lease is non-empty" false;
    failwith "empty lease"
  | `Already_leased lease_id ->
    check ("no outstanding lease: " ^ lease_id) false;
    failwith "already leased"
  | `Error error ->
    check
      ("lease succeeds: " ^ Keeper_chat_queue.mutation_error_to_string error)
      false;
    failwith "lease failed"

let ids items =
  List.map
    (fun (item : Keeper_chat_queue.leased_message) ->
       Keeper_chat_queue.Receipt_id.to_string item.receipt_id)
    items

let active_ids items =
  List.map
    (fun (item : Keeper_chat_queue.active_receipt) ->
       Keeper_chat_queue.Receipt_id.to_string item.receipt_id)
    items

let terminal_ids items =
  List.map
    (fun (item : Keeper_chat_queue.receipt_view) ->
       Keeper_chat_queue.Receipt_id.to_string item.receipt_id)
    items

let snapshot_path_for_config ~(config : Workspace.config) ~keeper_name =
  Filename.concat
    (Filename.concat (Workspace.keepers_runtime_dir config) keeper_name)
    "chat-queue.json"

let snapshot_path ~base_path ~keeper_name =
  snapshot_path_for_config ~config:(workspace_config base_path) ~keeper_name

let save_raw path content =
  Fs_compat.mkdir_p (Filename.dirname path);
  match Fs_compat.save_file_atomic path content with
  | Ok () -> ()
  | Error error -> failwith error

let read_raw path =
  let channel = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr channel)
    (fun () -> really_input_string channel (in_channel_length channel))

let test_durable_receipt_lifecycle () =
  Printf.printf "Test: durable per-message Pending -> Inflight -> Delivered\n%!";
  with_base "keeper-chat-receipt" @@ fun base_path ->
  let keeper_name = "receipt-lifecycle" in
  ignore (configure base_path : Keeper_chat_queue.configure_report);
  let enqueued = enqueue_exn ~keeper_name (message "keep this message") in
  let receipt_id = Keeper_chat_queue.Receipt_id.to_string enqueued.receipt_id in
  check "receipt is minted before committed enqueue returns" (receipt_id <> "");
  check "enqueue revision is one" (Int64.equal enqueued.revision 1L);
  let pending = Keeper_chat_queue.snapshot ~keeper_name in
  check "receipt starts pending" (active_ids pending.pending = [ receipt_id ]);
  let lease = lease_exn ~keeper_name in
  check "lease carries the exact receipt" (ids lease.items = [ receipt_id ]);
  let inflight = Keeper_chat_queue.snapshot ~keeper_name in
  check "pending is empty while receipt is inflight" (inflight.pending = []);
  check "diagnostic snapshot exposes inflight" (active_ids inflight.inflight = [ receipt_id ]);
  (match
     Keeper_chat_queue.finalize ~keeper_name ~lease_id:lease.lease_id
       ~outcome:
         (Keeper_chat_queue.Mark_delivered
            { completed_at = 3.0; outcome_ref = Some "chat-row-1" })
   with
   | `Finalized receipt_ids ->
     check
       "finalize reports every receipt"
       (List.map Keeper_chat_queue.Receipt_id.to_string receipt_ids = [ receipt_id ])
   | `Unknown_lease | `Error _ -> check "finalize succeeds" false);
  let terminal = Keeper_chat_queue.snapshot ~keeper_name in
  check "terminal receipt leaves active queue" (terminal.pending = [] && terminal.inflight = []);
  check "terminal receipt remains queryable" (terminal_ids terminal.terminal = [ receipt_id ]);
  (match terminal.terminal with
   | [ { state = Delivered { outcome_ref = Some "chat-row-1"; _ }; _ } ] ->
     check "delivered outcome ref is durable" true
   | _ -> check "delivered outcome ref is durable" false);
  (match
     Keeper_chat_queue.lookup_receipt ~keeper_name
       ~receipt_id:enqueued.receipt_id
   with
   | Ok { revision; receipt = Some { state = Delivered _; _ } } ->
     check "receipt lookup returns terminal state" true;
     check "receipt lookup returns its atomic snapshot revision"
       (Int64.equal revision terminal.revision)
   | Ok { receipt = Some _; _ } | Ok { receipt = None; _ } | Error _ ->
     check "receipt lookup returns terminal state" false;
     check "receipt lookup returns its atomic snapshot revision" false);
  let persisted =
    Safe_ops.read_json_file_safe (snapshot_path ~base_path ~keeper_name)
  in
  (match persisted with
   | Error _ -> check "terminal snapshot is readable" false
   | Ok (`Assoc fields) ->
     (match List.assoc_opt "receipts" fields with
      | Some (`List [ `Assoc receipt_fields ]) ->
        check
          "terminal record discards message body"
          (not (List.mem_assoc "message" receipt_fields))
      | _ -> check "terminal record is present" false)
   | Ok _ -> check "terminal snapshot is an object" false)

let test_coalesced_finalize_preserves_all_receipts () =
  Printf.printf "Test: coalescing never erases per-message receipts\n%!";
  with_base "keeper-chat-coalesce-receipts" @@ fun base_path ->
  let keeper_name = "coalesced-receipts" in
  ignore (configure base_path : Keeper_chat_queue.configure_report);
  let first =
    enqueue_exn ~keeper_name
      (message ~timestamp:1.0 ~attachments:[ attachment "first" ] "first")
  in
  let second =
    enqueue_exn ~keeper_name
      (message ~timestamp:2.0 ~user_blocks:[ image_block "second-image" ]
         ~attachments:[ attachment "second" ] "second")
  in
  let expected =
    [ Keeper_chat_queue.Receipt_id.to_string first.receipt_id
    ; Keeper_chat_queue.Receipt_id.to_string second.receipt_id
    ]
  in
  let lease = lease_exn ~keeper_name in
  check "one lease carries both receipt ids" (ids lease.items = expected);
  (match Keeper_chat_queue.merge_batch lease.items with
   | Some merged ->
     check "coalesced content remains FIFO" (merged.content = "first\n\nsecond");
     check "coalesced attachments remain FIFO"
       (List.map
          (fun (item : Keeper_chat_store.attachment) -> item.id)
          merged.attachments
        = [ "first"; "second" ]);
     check "coalesced semantic blocks remain visible"
       (Keeper_multimodal_input.modalities merged.user_blocks = [ "image" ]);
     check "coalesced timestamp belongs to the head receipt"
       (Float.equal merged.timestamp 1.0)
   | None -> check "coalesced payload exists" false);
  (match
     Keeper_chat_queue.finalize ~keeper_name ~lease_id:lease.lease_id
       ~outcome:
         (Mark_failed
            { completed_at = 4.0
            ; kind = Turn_failed
            ; detail = "provider returned a terminal error"
            ; outcome_ref = Some "failure-row-1"
            })
   with
   | `Finalized receipt_ids ->
     check
       "failed coalesced turn finalizes each receipt"
       (List.map Keeper_chat_queue.Receipt_id.to_string receipt_ids = expected)
   | `Unknown_lease | `Error _ -> check "coalesced finalization succeeds" false);
  let snapshot = Keeper_chat_queue.snapshot ~keeper_name in
  check "both failed receipts remain queryable" (terminal_ids snapshot.terminal = expected)

let test_source_boundaries_preserve_fifo_runs () =
  Printf.printf "Test: lease batches stop at typed connector source boundaries\n%!";
  with_base "keeper-chat-source-boundary" @@ fun base_path ->
  let keeper_name = "source-boundary" in
  let discord =
    Keeper_chat_queue.Discord { channel_id = "channel"; user_id = "user" }
  in
  ignore (configure base_path : Keeper_chat_queue.configure_report);
  List.iter
    (fun queued -> ignore (enqueue_exn ~keeper_name queued : Keeper_chat_queue.enqueue_receipt))
    [ message ~timestamp:1.0 "dashboard-1"
    ; message ~timestamp:2.0 "dashboard-2"
    ; message ~source:discord ~timestamp:3.0 "discord"
    ; message ~timestamp:4.0 "dashboard-3"
    ];
  let take expected =
    let lease = lease_exn ~keeper_name in
    check "lease keeps one same-source FIFO run"
      (List.map
         (fun (item : Keeper_chat_queue.leased_message) -> item.message.content)
         lease.items
       = expected);
    ignore
      (Keeper_chat_queue.finalize ~keeper_name ~lease_id:lease.lease_id
         ~outcome:
           (Mark_delivered { completed_at = 4.0; outcome_ref = None }))
  in
  take [ "dashboard-1"; "dashboard-2" ];
  take [ "discord" ];
  take [ "dashboard-3" ];
  check "all typed source runs drain without reordering"
    (match Keeper_chat_queue.lease_batch ~keeper_name with
     | `Empty -> true
     | `Leased _ | `Already_leased _ | `Error _ -> false)

let test_nack_and_restart_preserve_receipt () =
  Printf.printf "Test: nack and restart replay preserve receipt identity\n%!";
  with_base "keeper-chat-replay-receipt" @@ fun base_path ->
  let keeper_name = "replay-receipt" in
  ignore (configure base_path : Keeper_chat_queue.configure_report);
  let enqueued = enqueue_exn ~keeper_name (message "retry me") in
  let expected = Keeper_chat_queue.Receipt_id.to_string enqueued.receipt_id in
  let first_lease = lease_exn ~keeper_name in
  (match Keeper_chat_queue.nack ~keeper_name ~lease_id:first_lease.lease_id with
   | `Requeued receipt_ids ->
     check
       "nack reports original receipt"
       (List.map Keeper_chat_queue.Receipt_id.to_string receipt_ids = [ expected ])
   | `Unknown_lease | `Error _ -> check "nack succeeds" false);
  check
    "nack returns same receipt to pending"
    (active_ids (Keeper_chat_queue.snapshot ~keeper_name).pending = [ expected ]);
  let crash_lease = lease_exn ~keeper_name in
  check "receipt is inflight before simulated crash" (ids crash_lease.items = [ expected ]);
  Keeper_chat_queue.For_testing.reset ();
  let report = configure_raw base_path in
  check "restart recovery is reported" (report.recovered_receipt_count = 1);
  let replay = Keeper_chat_queue.snapshot ~keeper_name in
  check "restart moves inflight back to pending" (replay.inflight = []);
  check "restart preserves receipt id" (active_ids replay.pending = [ expected ])

let test_persist_failures_roll_back () =
  Printf.printf "Test: every lifecycle persistence failure rolls back\n%!";
  with_base "keeper-chat-rollback" @@ fun base_path ->
  let keeper_name = "receipt-rollback" in
  ignore (configure base_path : Keeper_chat_queue.configure_report);
  let first = enqueue_exn ~keeper_name (message "first") in
  Keeper_chat_queue.For_testing.fail_next_persist ();
  (match Keeper_chat_queue.enqueue ~keeper_name (message "must roll back") with
   | Error (Persist_failed _) -> check "failed enqueue is typed" true
   | Ok _ | Error _ -> check "failed enqueue is typed" false);
  check
    "failed enqueue leaves prior pending receipt unchanged"
    (active_ids (Keeper_chat_queue.snapshot ~keeper_name).pending
     = [ Keeper_chat_queue.Receipt_id.to_string first.receipt_id ]);
  Keeper_chat_queue.For_testing.fail_next_persist ();
  (match Keeper_chat_queue.lease_batch ~keeper_name with
   | `Error (Persist_failed _) -> check "failed lease is typed" true
   | `Leased _ | `Empty | `Already_leased _ | `Error _ -> check "failed lease is typed" false);
  check "failed lease leaves receipt pending" ((Keeper_chat_queue.snapshot ~keeper_name).inflight = []);
  let lease = lease_exn ~keeper_name in
  Keeper_chat_queue.For_testing.fail_next_persist ();
  (match
     Keeper_chat_queue.finalize ~keeper_name ~lease_id:lease.lease_id
       ~outcome:(Mark_delivered { completed_at = 5.0; outcome_ref = None })
   with
   | `Error (Persist_failed _) -> check "failed finalize is typed" true
   | `Finalized _ | `Unknown_lease | `Error _ -> check "failed finalize is typed" false);
  check
    "failed finalize leaves original lease inflight"
    (active_ids (Keeper_chat_queue.snapshot ~keeper_name).inflight
     = [ Keeper_chat_queue.Receipt_id.to_string first.receipt_id ]);
  Keeper_chat_queue.For_testing.fail_next_persist ();
  (match Keeper_chat_queue.nack ~keeper_name ~lease_id:lease.lease_id with
   | `Error (Persist_failed _) -> check "failed nack is typed" true
   | `Requeued _ | `Unknown_lease | `Error _ -> check "failed nack is typed" false);
  check
    "failed nack leaves original lease inflight"
    ((Keeper_chat_queue.snapshot ~keeper_name).inflight <> [])

let v1_message_json ?(source = `Assoc [ "kind", `String "dashboard" ]) content =
  `Assoc
    [ "content", `String content
    ; "user_blocks", `List []
    ; "attachments", `List []
    ; "timestamp", `Float 1.0
    ; "source", source
    ]

let test_v1_atomic_migration () =
  Printf.printf "Test: safe v1 data has one atomic migration to strict v3\n%!";
  with_base "keeper-chat-v1-migration" @@ fun base_path ->
  let keeper_name = "v1-migration" in
  let path = snapshot_path ~base_path ~keeper_name in
  let v1 =
    `Assoc
      [ "schema", `String "keeper_chat_queue.v1"
      ; "items",
        `List
          [ v1_message_json "legacy pending" ]
      ; ( "inflight"
        , `Assoc
            [ "lease_id", `String "legacy-lease"
            ; "items", `List [ v1_message_json "legacy inflight" ]
            ] )
      ]
  in
  save_raw path (Yojson.Safe.pretty_to_string v1);
  let report = configure_raw base_path in
  check "migration is reported once" (report.migrated_keeper_count = 1);
  let migrated = Keeper_chat_queue.snapshot ~keeper_name in
  check "legacy inflight is replayed ahead of pending"
    (List.map
       (fun (receipt : Keeper_chat_queue.active_receipt) ->
          receipt.message.content)
       migrated.pending
     = [ "legacy inflight"; "legacy pending" ]);
  let migrated_ids = active_ids migrated.pending in
  check "migration mints durable ids" (List.for_all (( <> ) "") migrated_ids);
  Keeper_chat_queue.For_testing.reset ();
  let second_report = configure_raw base_path in
  check "v3 is not migrated again" (second_report.migrated_keeper_count = 0);
  check
    "migrated ids survive another restart"
    (active_ids (Keeper_chat_queue.snapshot ~keeper_name).pending = migrated_ids);
  (match Safe_ops.read_json_file_safe path with
   | Ok json ->
     check
       "migration atomically rewrites strict v3 schema"
       (Json_util.get_string json "schema" = Some "keeper_chat_queue.v3")
   | Error _ -> check "migrated snapshot is readable" false)

let test_v1_active_connector_requires_ownership_reconciliation () =
  Printf.printf
    "Test: active v1 connector data is quarantined until ownership is explicit\n%!";
  with_base "keeper-chat-v1-connector-ownership" @@ fun base_path ->
  let keeper_name = "v1-connector-ownership" in
  let path = snapshot_path ~base_path ~keeper_name in
  let legacy =
    `Assoc
      [ "schema", `String "keeper_chat_queue.v1"
      ; ( "items"
        , `List
            [ v1_message_json
                ~source:
                  (`Assoc
                     [ "kind", `String "slack"
                     ; "channel", `String "C-legacy"
                     ; "user_id", `String "U-legacy"
                     ])
                "already recorded upstream?"
            ] )
      ; "inflight", `Null
      ]
    |> Yojson.Safe.pretty_to_string
  in
  save_raw path legacy;
  let report = configure_raw base_path in
  check "ambiguous v1 connector receipt is a typed migration failure"
    (match report.load_errors with
     | [ Some name, { Keeper_chat_queue.kind = Migration_failed; _ } ] ->
       String.equal name keeper_name
     | _ -> false);
  check "ambiguous v1 bytes are not rewritten"
    (String.equal legacy (read_raw path));
  check "ambiguous v1 queue cannot accept new writes"
    (match Keeper_chat_queue.enqueue ~keeper_name (message "must not overwrite") with
     | Error (Snapshot_unavailable { kind = Migration_failed; _ }) -> true
     | Ok _ | Error _ -> false)

let test_v2_active_connector_requires_ownership_reconciliation () =
  Printf.printf
    "Test: active v2 connector data is quarantined until ownership is explicit\n%!";
  with_base "keeper-chat-v2-connector-ownership" @@ fun base_path ->
  let keeper_name = "v2-connector-ownership" in
  let path = snapshot_path ~base_path ~keeper_name in
  let legacy =
    `Assoc
      [ "schema", `String "keeper_chat_queue.v2"
      ; "revision", `Int 7
      ; ( "receipts"
        , `List
            [ `Assoc
                [ ( "receipt_id"
                  , `String
                      "chatq_00000000-0000-4000-8000-000000000207" )
                ; "state", `Assoc [ "kind", `String "pending" ]
                ; ( "message"
                  , `Assoc
                      [ "content", `String "already recorded upstream?"
                      ; "user_blocks", `List []
                      ; "attachments", `List []
                      ; "timestamp", `Float 1.0
                      ; ( "source"
                        , `Assoc
                            [ "kind", `String "slack"
                            ; "channel_id", `String "C-legacy"
                            ; "user_id", `String "U-legacy"
                            ; "user_name", `String "Legacy user"
                            ; "team_id", `String "T-legacy"
                            ; "thread_ts", `String "171.001"
                            ] )
                      ] )
                ]
            ] )
      ]
    |> Yojson.Safe.pretty_to_string
  in
  save_raw path legacy;
  let report = configure_raw base_path in
  check "ambiguous v2 connector receipt is a typed migration failure"
    (match report.load_errors with
     | [ Some name, { Keeper_chat_queue.kind = Migration_failed; _ } ] ->
       String.equal name keeper_name
     | _ -> false);
  check "ambiguous v2 bytes are not rewritten"
    (String.equal legacy (read_raw path));
  check "ambiguous v2 connector remains unavailable for dequeue"
    (match Keeper_chat_queue.lease_batch ~keeper_name with
     | `Error (Snapshot_unavailable { kind = Migration_failed; _ }) -> true
     | `Leased _ | `Already_leased _ | `Empty | `Error _ -> false)

let test_corrupt_snapshot_is_quarantined () =
  Printf.printf "Test: corrupt snapshot is explicit and never overwritten as empty\n%!";
  with_base "keeper-chat-corrupt" @@ fun base_path ->
  let keeper_name = "corrupt-snapshot" in
  let path = snapshot_path ~base_path ~keeper_name in
  let corrupt = "{ definitely-not-json" in
  save_raw path corrupt;
  let report = configure_raw base_path in
  check "configure reports corrupt keeper" (List.length report.load_errors = 1);
  let snapshot = Keeper_chat_queue.snapshot ~keeper_name in
  check "diagnostic snapshot carries load error" (List.length snapshot.load_errors = 1);
  (match Keeper_chat_queue.enqueue ~keeper_name (message "must not overwrite") with
   | Error (Snapshot_unavailable { kind = Read_failed; _ }) ->
     check "enqueue fails closed on unreadable snapshot" true
   | Error (Snapshot_unavailable { kind = Parse_failed; _ }) ->
     check "enqueue fails closed on malformed snapshot" true
   | Ok _ | Error _ -> check "enqueue fails closed on corrupt snapshot" false);
  let unknown_id =
    match
      Keeper_chat_queue.Receipt_id.of_string
        "chatq_00000000-0000-4000-8000-000000000001"
    with
    | Ok receipt_id -> receipt_id
    | Error error -> failwith error
  in
  (match Keeper_chat_queue.lookup_receipt ~keeper_name ~receipt_id:unknown_id with
   | Error (Snapshot_unavailable _) ->
     check "receipt lookup does not collapse unreadable into absent" true
   | Ok _ | Error _ ->
     check "receipt lookup does not collapse unreadable into absent" false);
  check "corrupt bytes remain untouched" (String.equal (read_raw path) corrupt)

let test_invalid_v2_is_not_a_compatibility_fallback () =
  Printf.printf "Test: malformed v2 is a parse error, never an empty fallback\n%!";
  with_base "keeper-chat-invalid-v2" @@ fun base_path ->
  let keeper_name = "invalid-v2" in
  let path = snapshot_path ~base_path ~keeper_name in
  let invalid_v2 =
    `Assoc
      [ "schema", `String "keeper_chat_queue.v2"
      ; "revision", `Int 9
      ; "receipts",
        `List
          [ `Assoc
              [ "receipt_id",
                `String "chatq_00000000-0000-4000-8000-000000000009"
              ; "state", `Assoc [ "kind", `String "inflight" ]
              ]
          ]
      ]
    |> Yojson.Safe.pretty_to_string
  in
  save_raw path invalid_v2;
  let report = configure_raw base_path in
  (match report.load_errors with
   | [ (Some name, { kind = Parse_failed; _ }) ] ->
     check "strict v2 parse failure names the keeper" (name = keeper_name)
   | _ -> check "strict v2 parse failure is explicit" false);
  (match Keeper_chat_queue.enqueue ~keeper_name (message "must not replace v2") with
   | Error (Snapshot_unavailable { kind = Parse_failed; _ }) ->
     check "malformed v2 keeper is quarantined" true
   | Ok _ | Error _ -> check "malformed v2 keeper is quarantined" false);
  check "malformed v2 bytes remain untouched" (String.equal (read_raw path) invalid_v2)

let test_invalid_v2_attachment_is_not_silently_dropped () =
  Printf.printf "Test: malformed v2 attachments fail instead of disappearing\n%!";
  with_base "keeper-chat-invalid-attachment" @@ fun base_path ->
  let keeper_name = "invalid-attachment" in
  let path = snapshot_path ~base_path ~keeper_name in
  let invalid =
    `Assoc
      [ "schema", `String "keeper_chat_queue.v2"
      ; "revision", `Int 1
      ; ( "receipts"
        , `List
            [ `Assoc
                [ ( "receipt_id"
                  , `String
                      "chatq_00000000-0000-4000-8000-000000000010" )
                ; "state", `Assoc [ "kind", `String "pending" ]
                ; ( "message"
                  , `Assoc
                      [ "content", `String "attachment must survive"
                      ; "user_blocks", `List []
                      ; ( "attachments"
                        , `List
                            [ `Assoc
                                [ "id", `String ""
                                ; "type", `String "file"
                                ; "name", `String "broken.txt"
                                ; "size", `Int 1
                                ; "mime_type", `String "text/plain"
                                ; "data", `String "payload"
                                ]
                            ] )
                      ; "timestamp", `Float 1.0
                      ; "source", `Assoc [ "kind", `String "dashboard" ]
                      ] )
                ]
            ] )
      ]
    |> Yojson.Safe.pretty_to_string
  in
  save_raw path invalid;
  let report = configure_raw base_path in
  (match report.load_errors with
   | [ (Some name, { kind = Parse_failed; _ }) ] ->
     check "malformed attachment quarantines its keeper"
       (String.equal name keeper_name)
   | _ -> check "malformed attachment is an explicit parse failure" false);
  check "malformed attachment bytes remain untouched"
    (String.equal (read_raw path) invalid)

let test_revision_domain_does_not_wrap () =
  Printf.printf "Test: revision exhaustion fails closed without int64 wrap\n%!";
  with_base "keeper-chat-revision-domain" @@ fun base_path ->
  let keeper_name = "revision-domain" in
  let path = snapshot_path ~base_path ~keeper_name in
  let at_limit =
    `Assoc
      [ "schema", `String "keeper_chat_queue.v2"
      ; "revision", `Intlit "9007199254740991"
      ; "receipts", `List []
      ]
    |> Yojson.Safe.pretty_to_string
  in
  save_raw path at_limit;
  let report = configure_raw base_path in
  check "maximum exact JSON revision remains readable" (report.load_errors = []);
  let configured_snapshot = read_raw path in
  (match Keeper_chat_queue.enqueue ~keeper_name (message "must not wrap") with
   | Error Keeper_chat_queue.Revision_exhausted ->
     check "next mutation reports revision exhaustion" true
   | Ok _ | Error _ -> check "next mutation reports revision exhaustion" false);
  check "revision exhaustion leaves the snapshot untouched"
    (String.equal (read_raw path) configured_snapshot)

let test_revision_outside_json_domain_is_rejected () =
  Printf.printf "Test: revision above the exact JSON domain is quarantined\n%!";
  with_base "keeper-chat-revision-too-large" @@ fun base_path ->
  let keeper_name = "revision-too-large" in
  let path = snapshot_path ~base_path ~keeper_name in
  let too_large =
    `Assoc
      [ "schema", `String "keeper_chat_queue.v2"
      ; "revision", `Intlit "9007199254740992"
      ; "receipts", `List []
      ]
    |> Yojson.Safe.pretty_to_string
  in
  save_raw path too_large;
  let report = configure_raw base_path in
  (match report.load_errors with
   | [ (Some name, { kind = Parse_failed; _ }) ] ->
     check "unsafe JSON revision names the quarantined keeper"
       (String.equal name keeper_name)
   | _ -> check "unsafe JSON revision is an explicit parse failure" false);
  check "unsafe revision bytes remain untouched"
    (String.equal (read_raw path) too_large)

let test_revision_recovery_exhaustion_is_quarantined () =
  Printf.printf "Test: max-revision inflight recovery fails without overwrite\n%!";
  with_base "keeper-chat-recovery-exhausted" @@ fun base_path ->
  let keeper_name = "recovery-exhausted" in
  let path = snapshot_path ~base_path ~keeper_name in
  let at_limit_inflight =
    `Assoc
      [ "schema", `String "keeper_chat_queue.v2"
      ; "revision", `Intlit "9007199254740991"
      ; ( "receipts"
        , `List
            [ `Assoc
                [ ( "receipt_id"
                  , `String
                      "chatq_00000000-0000-4000-8000-000000000099" )
                ; ( "state"
                  , `Assoc
                      [ "kind", `String "inflight"
                      ; "lease_id", `String "lease-before-restart"
                      ; "started_at", `Float 1.0
                      ] )
                ; "message", v1_message_json "replay me"
                ]
            ] )
      ]
    |> Yojson.Safe.pretty_to_string
  in
  save_raw path at_limit_inflight;
  let report = configure_raw base_path in
  (match report.load_errors with
   | [ (Some name, { kind = Recovery_failed; _ }) ] ->
     check "recovery exhaustion names the quarantined keeper"
       (String.equal name keeper_name)
   | _ -> check "recovery exhaustion is explicit" false);
  check "failed recovery preserves the inflight snapshot bytes"
    (String.equal (read_raw path) at_limit_inflight)

let test_post_commit_observer_is_central_and_unlocked () =
  Printf.printf "Test: one post-commit observer sees every mutation outside locks\n%!";
  with_base "keeper-chat-observer" @@ fun base_path ->
  let keeper_name = "transition-observer" in
  ignore (configure base_path : Keeper_chat_queue.configure_report);
  let revisions = ref [] in
  Keeper_chat_queue.set_transition_observer
    (Some
       (fun ~keeper_name:observed ~revision ->
          (* Re-entering snapshot would deadlock if the callback ran under the
             entry mutex. *)
          ignore (Keeper_chat_queue.snapshot ~keeper_name:observed : Keeper_chat_queue.diagnostic_snapshot);
          revisions := revision :: !revisions));
  ignore (enqueue_exn ~keeper_name (message "observe") : Keeper_chat_queue.enqueue_receipt);
  let first = lease_exn ~keeper_name in
  ignore (Keeper_chat_queue.nack ~keeper_name ~lease_id:first.lease_id);
  let second = lease_exn ~keeper_name in
  ignore
    (Keeper_chat_queue.finalize ~keeper_name ~lease_id:second.lease_id
       ~outcome:(Mark_delivered { completed_at = 6.0; outcome_ref = None }));
  check
    "observer sees enqueue, lease, nack, lease, finalize exactly once"
    (List.rev !revisions = [ 1L; 2L; 3L; 4L; 5L ])

let test_reconfigure_does_not_leak_receipts_across_base_paths () =
  Printf.printf "Test: BasePath reconfiguration clears the in-memory registry\n%!";
  with_base "keeper-chat-base-a" @@ fun first_base ->
  let second_base = temp_dir "keeper-chat-base-b" in
  Fun.protect
    ~finally:(fun () -> rm_rf second_base)
    (fun () ->
      let keeper_name = "base-boundary" in
      ignore (configure first_base : Keeper_chat_queue.configure_report);
      let first_receipt = enqueue_exn ~keeper_name (message "first workspace") in
      check
        "first BasePath has one receipt"
        (active_ids (Keeper_chat_queue.snapshot ~keeper_name).pending
         = [ Keeper_chat_queue.Receipt_id.to_string first_receipt.receipt_id ]);
      let first_path = snapshot_path ~base_path:first_base ~keeper_name in
      let first_snapshot_bytes = read_raw first_path in
      ignore
        (configure_raw second_base
          : Keeper_chat_queue.configure_report);
      let second_snapshot = Keeper_chat_queue.snapshot ~keeper_name in
      check
        "second BasePath does not inherit the first registry"
        (second_snapshot.pending = [] && second_snapshot.inflight = []
         && second_snapshot.terminal = []);
      ignore (enqueue_exn ~keeper_name (message "second workspace"));
      check
        "mutating the second BasePath leaves the first snapshot untouched"
        (String.equal (read_raw first_path) first_snapshot_bytes))

let test_cluster_config_is_the_queue_storage_boundary () =
  Printf.printf "Test: queue snapshots follow the canonical cluster path\n%!";
  with_base "keeper-chat-cluster-boundary" @@ fun base_path ->
  let keeper_name = "cluster-boundary" in
  let first_config = workspace_config ~cluster_name:"first-team" base_path in
  let second_config = workspace_config ~cluster_name:"second-team" base_path in
  let first_path = snapshot_path_for_config ~config:first_config ~keeper_name in
  let second_path = snapshot_path_for_config ~config:second_config ~keeper_name in
  ignore
    (Keeper_chat_queue.configure_persistence ~config:first_config
      : Keeper_chat_queue.configure_report);
  check "configured queue accepts the same live workspace root"
    (Keeper_chat_queue.persistence_matches_config ~config:first_config);
  check "configured queue rejects a different live workspace root"
    (not (Keeper_chat_queue.persistence_matches_config ~config:second_config));
  let first_receipt =
    enqueue_exn ~keeper_name (message "first cluster message")
  in
  check "first cluster snapshot is written under its canonical Keeper root"
    (Sys.file_exists first_path);
  check "first cluster write does not create the second cluster snapshot"
    (not (Sys.file_exists second_path));
  ignore
    (Keeper_chat_queue.configure_persistence ~config:second_config
      : Keeper_chat_queue.configure_report);
  check "reconfiguration changes the accepted workspace root"
    (Keeper_chat_queue.persistence_matches_config ~config:second_config
     && not (Keeper_chat_queue.persistence_matches_config ~config:first_config));
  check "second cluster starts with an empty in-memory queue"
    ((Keeper_chat_queue.snapshot ~keeper_name).pending = []);
  let second_receipt =
    enqueue_exn ~keeper_name (message "second cluster message")
  in
  check "second cluster snapshot is written under its canonical Keeper root"
    (Sys.file_exists second_path);
  ignore
    (Keeper_chat_queue.configure_persistence ~config:first_config
      : Keeper_chat_queue.configure_report);
  check "reconfiguring the first cluster restores only its receipt"
    (active_ids (Keeper_chat_queue.snapshot ~keeper_name).pending
     = [ Keeper_chat_queue.Receipt_id.to_string first_receipt.receipt_id ]);
  check "cluster snapshots carry different receipt identities"
    (not
       (Keeper_chat_queue.Receipt_id.equal
          first_receipt.receipt_id
          second_receipt.receipt_id))

let test_nondefault_cluster_never_infers_from_default_snapshots () =
  Printf.printf
    "Test: non-default cluster never scans or infers from default snapshots\n%!";
  with_base "keeper-chat-cluster-legacy" @@ fun base_path ->
  let keeper_name = "legacy-cluster-owner" in
  let default_config = workspace_config base_path in
  let cluster_config = workspace_config ~cluster_name:"verified-team" base_path in
  ignore
    (Keeper_chat_queue.configure_persistence ~config:default_config
      : Keeper_chat_queue.configure_report);
  let default_receipt =
    enqueue_exn ~keeper_name (message "default cluster durable message")
  in
  let default_path = snapshot_path_for_config ~config:default_config ~keeper_name in
  let canonical_path =
    snapshot_path_for_config ~config:cluster_config ~keeper_name
  in
  let default_bytes = read_raw default_path in
  let report = Keeper_chat_queue.configure_persistence ~config:cluster_config in
  check "non-default cluster configuration does not inspect default data"
    (report.load_errors = []);
  check "non-default cluster owns an independently configured queue"
    (Keeper_chat_queue.persistence_configured ());
  check "non-default cluster starts from its explicit canonical namespace"
    ((Keeper_chat_queue.snapshot ~keeper_name).pending = []);
  check "default cluster bytes remain untouched"
    (String.equal default_bytes (read_raw default_path));
  let cluster_receipt =
    enqueue_exn ~keeper_name (message "verified-team durable message")
  in
  check "non-default write uses only the canonical cluster path"
    (Sys.file_exists canonical_path
     && String.equal default_bytes (read_raw default_path));
  check "cluster receipt identity is independent"
    (not
       (Keeper_chat_queue.Receipt_id.equal
          default_receipt.receipt_id cluster_receipt.receipt_id));
  ignore
    (Keeper_chat_queue.configure_persistence ~config:default_config
      : Keeper_chat_queue.configure_report);
  check "returning to default restores only the default receipt"
    (active_ids (Keeper_chat_queue.snapshot ~keeper_name).pending
     = [ Keeper_chat_queue.Receipt_id.to_string default_receipt.receipt_id ])

let test_snapshot_is_atomically_replaced_with_owner_only_permissions () =
  Printf.printf "Test: sensitive queue snapshots are always owner-only\n%!";
  with_base "keeper-chat-private-snapshot" @@ fun base_path ->
  let keeper_name = "private-snapshot" in
  ignore (configure base_path : Keeper_chat_queue.configure_report);
  ignore
    (enqueue_exn ~keeper_name (message "secret prompt")
      : Keeper_chat_queue.enqueue_receipt);
  let path = snapshot_path ~base_path ~keeper_name in
  let permissions () = (Unix.stat path).Unix.st_perm land 0o777 in
  check "new queue snapshot has exact 0600 permissions"
    (permissions () = 0o600);
  Unix.chmod path 0o644;
  ignore
    (enqueue_exn ~keeper_name
       (message ~attachments:[ attachment "private-attachment" ]
          "second secret prompt")
      : Keeper_chat_queue.enqueue_receipt);
  check "atomic replacement repairs a permissive prior snapshot to 0600"
    (permissions () = 0o600)

let test_snapshot_path_rejects_parent_segments () =
  Printf.printf "Test: queue snapshot paths reject parent-directory segments\n%!";
  with_base "keeper-chat-invalid-path" @@ fun base_path ->
  ignore (configure base_path : Keeper_chat_queue.configure_report);
  (match Keeper_chat_queue.enqueue ~keeper_name:".." (message "escape") with
   | Error (Snapshot_unavailable { kind = Invalid_path; _ }) ->
     check "parent segment is a typed invalid path" true
   | Ok _ | Error _ -> check "parent segment is a typed invalid path" false);
  check "invalid Keeper path creates no queue snapshot outside its lane"
    (not
       (Sys.file_exists
          (Filename.concat
             (Filename.dirname
                (Workspace.keepers_runtime_dir (workspace_config base_path)))
             "chat-queue.json")))

let test_writer_rejects_unloadable_values_before_commit () =
  Printf.printf "Test: writer accepts only values the strict loader can replay\n%!";
  with_base "keeper-chat-writer-schema" @@ fun base_path ->
  let keeper_name = "writer-schema" in
  ignore (configure base_path : Keeper_chat_queue.configure_report);
  (match
     Keeper_chat_queue.enqueue ~keeper_name
       (message
          ~source:
            (Keeper_chat_queue.Slack
               { channel_id = ""
               ; user_id = "U1"
               ; user_name = "User"
               ; team_id = None
               ; thread_ts = Some "171.001"
               })
          "invalid source")
   with
   | Error (Keeper_chat_queue.Invalid_input _) ->
     check "invalid source is rejected before acknowledgement" true
   | Ok _ | Error _ -> check "invalid source is rejected before acknowledgement" false);
  check "invalid source leaves the queue unchanged"
    ((Keeper_chat_queue.snapshot ~keeper_name).pending = []);
  ignore (enqueue_exn ~keeper_name (message "valid") : Keeper_chat_queue.enqueue_receipt);
  let lease = lease_exn ~keeper_name in
  (match
     Keeper_chat_queue.finalize ~keeper_name ~lease_id:lease.lease_id
       ~outcome:
         (Mark_failed
            { completed_at = 3.0
            ; kind = Delivery_failed
            ; detail = "   "
            ; outcome_ref = None
            })
   with
   | `Error (Keeper_chat_queue.Invalid_input _) ->
     check "invalid terminal detail is rejected" true
   | `Finalized _ | `Unknown_lease | `Error _ ->
     check "invalid terminal detail is rejected" false);
  check "rejected terminal update leaves receipt inflight"
    (List.length (Keeper_chat_queue.snapshot ~keeper_name).inflight = 1)

let test_transcript_failure_retains_queued_message_for_recovery () =
  Printf.printf
    "Test: transcript persistence failure retains queued provenance in terminal storage\n%!";
  with_base "keeper-chat-transcript-failure-retention" @@ fun base_path ->
  let keeper_name = "transcript-failure-retention" in
  ignore (configure base_path : Keeper_chat_queue.configure_report);
  let original = message "prompt must remain recoverable" in
  let receipt = enqueue_exn ~keeper_name original in
  let lease = lease_exn ~keeper_name in
  (match
     Keeper_chat_queue.finalize ~keeper_name ~lease_id:lease.lease_id
       ~outcome:
         (Mark_failed
            { completed_at = 9.0
            ; kind = Transcript_persist_failed
            ; detail = "chat transcript append failed"
            ; outcome_ref = None
            })
   with
   | `Finalized [ finalized ] ->
     check "transcript failure finalizes the accepted receipt"
       (Keeper_chat_queue.Receipt_id.equal receipt.receipt_id finalized)
   | `Finalized _ | `Unknown_lease | `Error _ ->
     check "transcript failure reaches terminal storage" false);
  let path = snapshot_path ~base_path ~keeper_name in
  (match Safe_ops.read_json_file_safe path with
   | Error _ -> check "transcript failure snapshot remains readable" false
   | Ok json ->
     let retained_content =
       Yojson.Safe.Util.(
         json |> member "receipts" |> index 0 |> member "message"
         |> member "content" |> to_string_option)
     in
     check "terminal transcript failure retains exact prompt bytes"
       (retained_content = Some original.content));
  Keeper_chat_queue.For_testing.reset ();
  let report = configure_raw base_path in
  check "retained transcript failure reloads under strict v3"
    (report.load_errors = []);
  let snapshot = Keeper_chat_queue.snapshot ~keeper_name in
  check "retained failure is terminal, not silently redelivered"
    (snapshot.pending = [] && snapshot.inflight = []);
  check "retained failure identity survives restart"
    (match snapshot.terminal with
     | [ { receipt_id; state = Failed failure } ] ->
       Keeper_chat_queue.Receipt_id.equal receipt.receipt_id receipt_id
       && failure.kind = Transcript_persist_failed
     | _ -> false)

let test_control_bearing_prompt_roundtrips_byte_for_byte () =
  Printf.printf "Test: JSON persistence does not sanitize prompt strings\n%!";
  with_base "keeper-chat-control-text" @@ fun base_path ->
  let keeper_name = "control-text" in
  let content = "[STATE] Grep\nNEXT\tConstraints BDI\000tail" in
  ignore (configure base_path : Keeper_chat_queue.configure_report);
  ignore (enqueue_exn ~keeper_name (message content) : Keeper_chat_queue.enqueue_receipt);
  let report = configure_raw base_path in
  check "control-bearing prompt reload has no schema errors" (report.load_errors = []);
  match (Keeper_chat_queue.snapshot ~keeper_name).pending with
  | [ { message; _ } ] ->
    check "prompt bytes are identical before and after restart"
      (String.equal content message.content)
  | _ -> check "one prompt receipt reloads" false

let test_connector_transcript_context_roundtrips_exactly () =
  Printf.printf
    "Test: connector transcript provenance survives an exact v3 restart\n%!";
  with_base "keeper-chat-context-roundtrip" @@ fun base_path ->
  let keeper_name = "context-roundtrip" in
  let mention =
    match Keeper_identity.Keeper_id.of_string "luna" with
    | Some mention -> mention
    | None -> failwith "canonical keeper id fixture"
  in
  let surface =
    Surface_ref.Slack
      { team_id = Some "T-exact"
      ; channel_id = "C-exact"
      ; thread_ts = Some "171.002"
      }
  in
  let speaker : Keeper_chat_store.speaker =
    { speaker_id = Some "U-exact"
    ; speaker_name = Some "Exact User"
    ; speaker_authority = Keeper_chat_store.External
    }
  in
  let queued : Keeper_chat_queue.queued_message =
    { content = "preserve provenance"
    ; user_blocks = []
    ; attachments = []
    ; timestamp = 42.25
    ; source =
        Keeper_chat_queue.Slack
          { channel_id = "C-exact"
          ; user_id = "U-exact"
          ; user_name = "Exact User"
          ; team_id = Some "T-exact"
          ; thread_ts = Some "171.002"
          }
    ; transcript_context =
        Some
          { surface
          ; conversation_id = Some "slack:channel:C-exact"
          ; external_message_id = Some "171.002-9"
          ; speaker
          ; extra_mentions = [ mention ]
          }
    ; transcript_ownership = Keeper_chat_queue.Queue_owned
    }
  in
  ignore (configure base_path : Keeper_chat_queue.configure_report);
  let receipt = enqueue_exn ~keeper_name queued in
  Keeper_chat_queue.For_testing.reset ();
  let report = configure_raw base_path in
  check "v3 connector context reload has no errors" (report.load_errors = []);
  match (Keeper_chat_queue.snapshot ~keeper_name).pending with
  | [ { receipt_id; message; _ } ] ->
    check "receipt identity survives context reload"
      (Keeper_chat_queue.Receipt_id.equal receipt.receipt_id receipt_id);
    check "queue ownership survives context reload"
      (message.transcript_ownership = Keeper_chat_queue.Queue_owned);
    (match message.transcript_context with
     | Some context ->
       check "typed surface survives context reload"
         (Surface_ref.equal surface context.surface);
       check "conversation and external ids survive context reload"
         (context.conversation_id = Some "slack:channel:C-exact"
          && context.external_message_id = Some "171.002-9");
       check "speaker identity survives context reload"
         (context.speaker = speaker);
       check "structured mentions survive context reload"
         (List.map Keeper_identity.Keeper_id.to_string context.extra_mentions
          = [ Keeper_identity.Keeper_id.to_string mention ])
     | None -> check "connector transcript context remains present" false)
  | _ -> check "one exact connector receipt reloads" false

let test_connector_transcript_context_mismatch_is_rejected () =
  Printf.printf
    "Test: connector source/context mismatch fails before acknowledgement\n%!";
  with_base "keeper-chat-context-mismatch" @@ fun base_path ->
  let keeper_name = "context-mismatch" in
  ignore (configure base_path : Keeper_chat_queue.configure_report);
  let invalid : Keeper_chat_queue.queued_message =
    { content = "must not commit"
    ; user_blocks = []
    ; attachments = []
    ; timestamp = 1.0
    ; source =
        Keeper_chat_queue.Slack
          { channel_id = "C1"
          ; user_id = "U1"
          ; user_name = "User"
          ; team_id = Some "T1"
          ; thread_ts = Some "171.001"
          }
    ; transcript_context =
        Some
          { surface =
              Surface_ref.Discord
                { guild_id = Some "G1"
                ; channel_id = "C1"
                ; parent_channel_id = None
                ; thread_id = None
                }
          ; conversation_id = None
          ; external_message_id = None
          ; speaker =
              { speaker_id = Some "U1"
              ; speaker_name = Some "User"
              ; speaker_authority = Keeper_chat_store.Owner
              }
          ; extra_mentions = []
          }
    ; transcript_ownership = Keeper_chat_queue.Queue_owned
    }
  in
  check "mismatched connector context is a typed invalid input"
    (match Keeper_chat_queue.enqueue ~keeper_name invalid with
     | Error (Keeper_chat_queue.Invalid_input _) -> true
     | Ok _ | Error _ -> false);
  check "mismatched connector context leaves no receipt"
    ((Keeper_chat_queue.snapshot ~keeper_name).pending = [])

let test_slack_threads_are_distinct_fifo_sources () =
  Printf.printf "Test: Slack thread identity is a coalescing boundary\n%!";
  let source thread_ts =
    Keeper_chat_queue.Slack
      { channel_id = "C1"
      ; user_id = "U1"
      ; user_name = "User"
      ; team_id = Some "T1"
      ; thread_ts = Some thread_ts
      }
  in
  check "same actor in different Slack threads does not coalesce"
    (not
       (Keeper_chat_queue.same_source
          (source "171.001")
          (source "171.002")))

let () =
  Eio_main.run @@ fun _environment ->
  test_durable_receipt_lifecycle ();
  test_coalesced_finalize_preserves_all_receipts ();
  test_source_boundaries_preserve_fifo_runs ();
  test_nack_and_restart_preserve_receipt ();
  test_persist_failures_roll_back ();
  test_v1_atomic_migration ();
  test_v1_active_connector_requires_ownership_reconciliation ();
  test_v2_active_connector_requires_ownership_reconciliation ();
  test_corrupt_snapshot_is_quarantined ();
  test_invalid_v2_is_not_a_compatibility_fallback ();
  test_invalid_v2_attachment_is_not_silently_dropped ();
  test_revision_domain_does_not_wrap ();
  test_revision_outside_json_domain_is_rejected ();
  test_revision_recovery_exhaustion_is_quarantined ();
  test_post_commit_observer_is_central_and_unlocked ();
  test_reconfigure_does_not_leak_receipts_across_base_paths ();
  test_cluster_config_is_the_queue_storage_boundary ();
  test_nondefault_cluster_never_infers_from_default_snapshots ();
  test_snapshot_is_atomically_replaced_with_owner_only_permissions ();
  test_snapshot_path_rejects_parent_segments ();
  test_writer_rejects_unloadable_values_before_commit ();
  test_transcript_failure_retains_queued_message_for_recovery ();
  test_control_bearing_prompt_roundtrips_byte_for_byte ();
  test_connector_transcript_context_roundtrips_exactly ();
  test_connector_transcript_context_mismatch_is_rejected ();
  test_slack_threads_are_distinct_fifo_sources ();
  if !failures > 0
  then begin
    Printf.printf "FAILED: %d check(s)\n%!" !failures;
    exit 1
  end
  else Printf.printf "All keeper_chat_coalescing checks passed\n%!"
