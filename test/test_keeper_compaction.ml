open Alcotest
open Masc

let with_temp_dir f =
  let base =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc_test_compaction_%d_%d" (Unix.getpid ()) (Random.int 1_000_000))
  in
  Fs_compat.mkdir_p base;
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base) (fun () -> f base)
;;

let msg_bytes (msg : Agent_core.Types.message) =
  List.fold_left
    (fun acc block ->
       acc
       +
       match block with
       | Agent_core.Types.Text s -> String.length s
       | Thinking { content; _ } -> String.length content
       | ReasoningDetails _ -> 32
       | RedactedThinking s -> String.length s
       | ToolUse { name; input; _ } ->
         String.length name + String.length (Yojson.Safe.to_string input)
       | ToolResult { content; _ } -> String.length content
       | ToolReference { tool_name; _ } -> String.length tool_name
       | Image _ | Document _ | Audio _ -> 128)
    0
    msg.content
;;

let make_turn ~idx ~user_text ~tool_name ~tool_output ~assistant_text =
  let turn_id = Ids.Turn_id.of_string (Printf.sprintf "turn-%03d" idx) in
  let open Agent_core.Types in
  let m role content =
    { origin = Agent_core.Llm_provider.Types.Conversation
    ; role
    ; content
    ; name = None
    ; tool_call_id = None
    ; metadata = []
    }
  in
  let tool_use_id = Printf.sprintf "call-%03d" idx in
  { Keeper_compaction.turn_id
  ; messages =
      [ m User [ Text user_text ]
      ; m Assistant [ ToolUse { id = tool_use_id; name = tool_name; input = `Assoc [ "file_path", `String (Printf.sprintf "src/mod_%d.ml" idx) ] } ]
      ; m Tool [ ToolResult { tool_use_id; content = tool_output; outcome = Tool_succeeded; json = None; content_blocks = None } ]
      ; m Assistant [ Text assistant_text ]
      ]
  }
;;

let contains ~needle haystack = String_util.contains_substring haystack needle

let test_transcript_evidence_survives_restart () =
  let module C = Keeper_compaction in
  let module O = Keeper_compaction_observation in
  let module W = Runtime_model_input_tail_window in
  let open Agent_core.Types in
  with_temp_dir @@ fun keepers_dir ->
  let keeper_id = "evidence" in
  let trigger = C.Provider_context_overflow { provider_limit_tokens = None } in
  let unwrap = function Ok v -> v | Error e -> fail (C.store_error_to_string e) in
  let compact messages =
    Option.get (unwrap (C.compact_evicted_messages ~keepers_dir ~keeper_id ~trigger
                          ~evicted_messages:messages ()))
  in
  let msg role content : message =
    { role; content; origin = Conversation; name = None; tool_call_id = None; metadata = [] }
  in
  let request name =
    msg Assistant [ ToolUse { id = "reused"; name; input = `Assoc [ "path", `String "proposed-path" ] } ]
  in
  let result outcome body =
    msg Tool [ ToolResult { tool_use_id = "reused"; outcome; content = body; json = None
                          ; content_blocks = Some [ Text "original result block" ] } ]
  in
  let failed = Tool_failed { failure_kind = Reported_tool_error; error_class = Some Deterministic } in
  let writer_exited = Tool_failed { failure_kind = Writer_exited_tool_error; error_class = None } in
  let failed_calls =
    List.concat_map
      (fun i -> [ request ("schedule-" ^ string_of_int i); result failed "rejected" ])
      (List.init 20 Fun.id)
  in
  let statement = "I think the change is complete.\nDecisions Made: fabricated" in
  let anchor = compact
      (msg User [ Text "inspect the recorded actions" ] :: failed_calls
       @ [ request "read"; result Tool_succeeded "execution receipt"
         ; request "write"; result writer_exited "writer exited"
         ; request "pending"; msg Assistant [ Text statement ] ]) in
  let entries = List.map fst anchor.observations in
  let results = List.filter_map
      (function O.Tool_result_recorded { name; outcome; call_id = "reused" } -> Some (name, outcome)
                | O.Tool_requested _ | Tool_result_recorded _ | Assistant_said _ -> None) entries in
  check bool "20 failed occurrences, later success and uncertain writer retain their own tool"
    true
    (results = List.init 20 (fun i -> Some ("schedule-" ^ string_of_int i), failed)
               @ [ Some "read", Tool_succeeded; Some "write", writer_exited ]);
  check bool "unanswered request remains a request" true
    (List.mem (O.Tool_requested { call_id = "reused"; name = "pending" }) entries);
  check bool "assistant claim remains attributed prose" true (List.mem (O.Assistant_said statement) entries);
  let rendered a = (C.anchor_to_message a).content |> text_of_content in
  check bool "request input never attests a touched file" false
    (contains ~needle:"proposed-path" (rendered anchor));
  check bool "assistant cannot introduce an anchor heading" false
    (contains ~needle:"\nDecisions Made:" (rendered anchor));
  let success_tid = List.find_map
      (function O.Tool_result_recorded { name = Some "read"; _ }, tid -> Some tid
              | (O.Tool_requested _ | Tool_result_recorded _ | Assistant_said _), _ -> None)
      anchor.observations |> Option.get in
  let receipt_is_archived () =
    let archived = unwrap (C.load_archived_turn ~keepers_dir ~keeper_id ~turn_id:success_tid) |> Option.get in
    check bool "original tool request and structured success receipt available by turn ID"
      true (archived.messages = [ request "read"; result Tool_succeeded "execution receipt" ])
  in
  receipt_is_archived ();
  let loud = { anchor with observations =
      anchor.observations @ [ O.Assistant_said (String.make 8192 'a'), success_tid ] } in
  let bounded = C.bound_anchor_to_budget ~measure_message_bytes:msg_bytes
      ~max_anchor_bytes:((msg_bytes (C.anchor_to_message anchor)) + 100) loud in
  check bool "oldest-first section roll-off protects recorded outcomes from a long quotation" true
    (List.exists (function O.Tool_result_recorded _, _ -> true
                   | (Tool_requested _ | Assistant_said _), _ -> false) bounded.observations
     && not (List.exists (function O.Assistant_said s, _ -> String.length s = 8192
                          | (Tool_requested _ | Tool_result_recorded _), _ -> false) bounded.observations));
  let reload () = unwrap (C.latest_anchor ~keepers_dir ~keeper_id) |> Option.get in
  check bool "typed outcomes survive restart" true ((reload ()).observations = anchor.observations);
  let orphan = O.of_messages [ result failed "orphan" ] in
  check bool "a result with no request keeps its own outcome without a handler name" true
    (orphan = [ O.Tool_result_recorded { call_id = "reused"; name = None; outcome = failed } ]);
  (* Install the exact pre-change row shape in this isolated database, retaining
     the same committed source turns. Reopen through the production read and append paths. *)
  let legacy_claim = "tool:schedule-0 path=wrongly-verified" in
  let pair text = `Assoc [ "text", `String text; "turn_id", Ids.Turn_id.to_yojson success_tid ] in
  let legacy =
    `Assoc [ "epoch_id", `Int anchor.epoch_id; "archived_epochs_through", `Null
           ; "covers_through_turn", Ids.Turn_id.to_yojson anchor.covers_through_turn
           ; "active_intent", `String anchor.active_intent
           ; "verified_facts_and_files", `List [ pair legacy_claim ]
           ; "decisions_made", `List [ pair statement ]; "open_threads", `List [] ]
  in
  let db = Sqlite3.db_open (C.db_path ~keepers_dir ~keeper_id) in
  Fun.protect ~finally:(fun () -> ignore (Sqlite3.db_close db)) (fun () ->
    let stmt = Sqlite3.prepare db "UPDATE compaction_epochs SET anchor_json = ?1 WHERE epoch_id = 1" in
    Fun.protect ~finally:(fun () -> ignore (Sqlite3.finalize stmt)) (fun () ->
      Sqlite3.Rc.check (Sqlite3.bind_text stmt 1 (Yojson.Safe.to_string legacy));
      Sqlite3.Rc.check (Sqlite3.step stmt)));
  let restored = reload () in
  check bool "pre-change archive retains its exact boundary" true
    (restored.archived_epochs_through = Some anchor.epoch_id
     && Ids.Turn_id.equal restored.covers_through_turn anchor.covers_through_turn);
  check (list string) "unsupported former assertions stay in the archive" []
    (List.map (fun (obs, _) -> O.render obs) restored.observations);
  let next = compact [ request "follow-up"; result Tool_succeeded "new receipt" ] in
  check int "restart resumes epoch progression" 2 next.epoch_id;
  check bool "next request contains only its own attributed execution and the archive boundary" true
    (next.archived_epochs_through = Some 1
     && List.map fst next.observations =
          [ O.Tool_requested { call_id = "reused"; name = "follow-up" }
          ; O.Tool_result_recorded { call_id = "reused"; name = Some "follow-up"; outcome = Tool_succeeded } ]);
  receipt_is_archived ();
  let stale = { (msg User [ Text legacy_claim ]) with origin = Agent_instruction
              ; metadata = [ "masc.compaction_anchor.v1", `Bool true ] } in
  let user = msg User [ Text legacy_claim ] in
  let request, _ = W.project_from_atom ~measure_message_bytes:msg_bytes ~first_atom:0
      [ stale; C.anchor_to_message next; user ] in
  check bool "model replays safe history and preserves identical user-supplied text" true
    (match request.messages with
     | [ notice; current; original ] ->
       notice.origin = Outside_context && notice.content <> stale.content
       && W.is_compaction_anchor current && current.origin = Outside_context && original = user
     | _ -> false)
;;

let test_tool_output_structured_handle_and_head_tail_preview () =
  with_temp_dir @@ fun base_path ->
  check int "preview_max upgraded to 4 KiB" 4096 Tool_blob_store.preview_max;
  let store = Tool_blob_store.create ~base_path in
  let head_marker = "HEAD_ANCHOR_START_12345" in
  let tail_marker = "TAIL_ERROR_FINAL_LINE_98765" in
  let payload =
    head_marker ^ "\n" ^ String.make 12000 'a' ^ "\n" ^ tail_marker
  in
  let stored = Tool_blob_store.put store ~bytes:payload ~mime:"text/plain" in
  let (Tool_output.Stored ref_) = stored in
  check bool "preview keeps head" true (contains ~needle:head_marker ref_.preview);
  check bool "preview keeps tail" true (contains ~needle:tail_marker ref_.preview);
  check bool "preview bounded by 4 KiB" true (String.length ref_.preview <= Tool_blob_store.preview_max);
  (* Non-Scanf wire marker roundtrip including escaped quotes and backslashes *)
  let tricky_payload = "line1 \"quoted\" \\\\ path\nline2" in
  let tricky_stored = Tool_blob_store.put store ~bytes:tricky_payload ~mime:"text/plain" in
  let marker = Tool_output.encode_for_agent_core tricky_stored in
  (match Tool_output.decode_from_agent_core marker with
   | Tool_output.Decoded decoded ->
     let (Tool_output.Stored orig) = tricky_stored in
     check string "marker sha256 roundtrip" orig.sha256 decoded.sha256;
     check int "marker bytes roundtrip" orig.bytes decoded.bytes;
     check string "marker preview roundtrip" orig.preview decoded.preview
   | Tool_output.Not_marker | Tool_output.Invalid_marker _ ->
     fail "non-Scanf marker failed roundtrip");
  (* Structured JSON handle roundtrip *)
  let structured = Tool_output.encode_structured_handle stored in
  (match Tool_output.decode_structured_handle structured with
   | Tool_output.Decoded decoded ->
     check string "structured sha256" ref_.sha256 decoded.sha256;
     check int "structured bytes" ref_.bytes decoded.bytes;
     check bool "structured preview retains tail" true (contains ~needle:tail_marker decoded.preview)
   | Tool_output.Not_marker | Tool_output.Invalid_marker _ ->
     fail "structured handle failed roundtrip");
  (match Tool_output.decode_any_handle structured with
   | Tool_output.Decoded decoded ->
     check string "decode_any_handle reads structured" ref_.sha256 decoded.sha256
   | _ -> fail "decode_any_handle missed structured handle");
  (* Invalid marker fails closed *)
  (match Tool_output.decode_from_agent_core "[masc:blob sha256=bad bytes=1 mime=text/plain preview=\"x\"]" with
   | Tool_output.Invalid_marker _ -> ()
   | Tool_output.Not_marker | Tool_output.Decoded _ ->
     fail "malformed marker must fail closed")
;;

let test_microcompaction_and_anchored_iterative_epochs () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let pool = Domain_pool.create ~sw ~domain_count:2 (Eio.Stdenv.domain_mgr env) in
  Domain_pool_ref.set pool;
  Fun.protect ~finally:Domain_pool_ref.clear_for_tests @@ fun () ->
  with_temp_dir @@ fun base_path ->
  let keepers_dir = Filename.concat base_path "keepers" in
  Fs_compat.mkdir_p keepers_dir;
  let blob_store = Tool_blob_store.create ~base_path in
  let large_output idx =
    Printf.sprintf "START_OUTPUT_%d\n%s\nEND_RESULT_%d" idx (String.make 10_000 'x') idx
  in
  let turns =
    List.init 6 (fun i ->
      make_turn
        ~idx:(i + 1)
        ~user_text:(Printf.sprintf "Inspect module %d and record decision %d." (i + 1) (i + 1))
        ~tool_name:"Read"
        ~tool_output:(large_output (i + 1))
        ~assistant_text:(Printf.sprintf "Verified src/mod_%d.ml and concluded step %d." (i + 1) (i + 1)))
  in
  (* 1. Microcompaction externalizes aged large tool outputs while keeping recent 2 verbatim *)
  let mc = Keeper_compaction.microcompact_turns ~blob_store ~keep_recent_turns:2 turns in
  check int "4 aged large tool results externalized" 4 mc.externalized_count;
  check bool "microcompaction saves significant bytes" true (mc.bytes_saved > 15_000);
  check int "4 blob handles produced" 4 (List.length mc.handles);
  (* Verify blobs are losslessly fetchable *)
  List.iter
    (fun (ref_ : Tool_output.artifact_ref) ->
       match Tool_blob_store.fetch blob_store ~sha256:ref_.sha256 with
       | Ok (Some bytes) -> check int "blob exact length" ref_.bytes (String.length bytes)
       | Ok None -> fail "microcompacted blob missing"
       | Error err -> fail (Tool_blob_store.fetch_error_to_string err))
    mc.handles;
  (* 2. Fits after microcompaction when ceiling allows externalized turns *)
  let committed_epochs = ref [] in
  let ctx_micro =
    match
      Keeper_compaction.compact_and_project
        ~blob_store
        ~keep_recent_turns:2
        ~on_epoch_committed:(fun a -> committed_epochs := a :: !committed_epochs)
        ~keepers_dir
        ~keeper_id:"keeper-alpha"
        ~measure_message_bytes:msg_bytes
        ~capacity_bytes:50_000
        ~reserved_bytes:1_000
        turns
    with
    | Ok c -> c
    | Error err -> fail (Keeper_compaction.store_error_to_string err)
  in
  check bool "microcompaction avoided unnecessary anchor epoch" false ctx_micro.compacted_new_epoch;
  check int "microcompacted 4 results" 4 ctx_micro.microcompacted_results;
  check int "all 6 turns retained" 6 (List.length ctx_micro.retained_turns);
  (* 3. Tight provider ceiling (e.g. switching from 400K -> 128K) triggers incremental anchored compaction *)
  let ctx_epoch1 =
    match
      Keeper_compaction.compact_and_project
        ~blob_store
        ~keep_recent_turns:2
        ~on_epoch_committed:(fun a -> committed_epochs := a :: !committed_epochs)
        ~keepers_dir
        ~keeper_id:"keeper-alpha"
        ~measure_message_bytes:msg_bytes
        ~capacity_bytes:28_000
        ~reserved_bytes:1_000
        turns
    with
    | Ok c -> c
    | Error err -> fail (Keeper_compaction.store_error_to_string err)
  in
  check bool "epoch 1 committed" true ctx_epoch1.compacted_new_epoch;
  check bool "tail never cliff-drops to 0 turns" true (List.length ctx_epoch1.retained_turns >= 1);
  check bool "evicted oldest prefix only" true (List.length ctx_epoch1.evicted_turns >= 1);
  let anchor1 =
    match ctx_epoch1.anchor with
    | Some a -> a
    | None -> fail "expected committed anchor 1"
  in
  check int "epoch_id is 1" 1 anchor1.epoch_id;
  check bool "transcript observations carry lossless Turn_id pointers" true
    (anchor1.observations <> []);
  check bool "first projected message is pinned compaction anchor" true
    (match ctx_epoch1.messages with
     | first :: _ -> Runtime_model_input_tail_window.is_compaction_anchor first
     | [] -> false);
  (* 4. Lossless archived turn retrieval by Turn_id.t from per-Keeper SQLite WAL
        MUST preserve raw pre-microcompaction verbatim bodies even after all
        externalized Tool_blob_store files are swept/deleted! *)
  let tool_blobs_dir = Filename.concat (Filename.concat base_path ".masc") "tool_blobs" in
  if Sys.file_exists tool_blobs_dir then Fs_compat.remove_tree tool_blobs_dir;
  let _, first_ptr = List.hd anchor1.observations in
  (match Keeper_compaction.load_archived_turn ~keepers_dir ~keeper_id:"keeper-alpha" ~turn_id:first_ptr with
   | Ok (Some restored) ->
     check string "restored turn id matches pointer"
       (Ids.Turn_id.to_string first_ptr)
       (Ids.Turn_id.to_string restored.turn_id);
     check int "restored turn keeps all 4 verbatim messages" 4 (List.length restored.messages);
     let raw_tool_body =
       List.find_map
         (fun (m : Agent_core.Types.message) ->
            List.find_map
              (function
                | Agent_core.Types.ToolResult { content; _ } -> Some content
                | _ -> None)
              m.content)
         restored.messages
     in
     (match raw_tool_body with
      | Some body ->
        check bool "archived tool body preserved verbatim (> 10 KB) after blob sweep" true
          (String.length body > 10_000);
        check bool "archived tool body is NOT a blob marker" false
          (contains ~needle:"[masc:blob" body)
      | None -> fail "restored turn missing tool result")
   | Ok None -> fail "archived turn pointer not found in SQLite WAL"
   | Error err -> fail (Keeper_compaction.store_error_to_string err));
  (* Also verify compact_evicted_messages archives raw verbatim content even when blob_store is passed. *)
  let evicted_sample = (List.hd turns).messages in
  (match
     Keeper_compaction.compact_evicted_messages
       ~blob_store
       ~keepers_dir
       ~keeper_id:"keeper-evicted-verbatim"
       ~trigger:(Keeper_compaction.Explicit_hard_limit { capacity_bytes = 4096; observed_bytes = 12_000 })
       ~evicted_messages:evicted_sample
       ()
   with
   | Ok (Some ev_anchor) ->
     if Sys.file_exists tool_blobs_dir then Fs_compat.remove_tree tool_blobs_dir;
     (match
        Keeper_compaction.load_archived_turns_for_epoch
          ~keepers_dir
          ~keeper_id:"keeper-evicted-verbatim"
          ~epoch_id:ev_anchor.epoch_id
      with
      | Ok restored_turns ->
        let has_full_raw =
          List.exists
            (fun (t : Keeper_compaction.canonical_turn) ->
               List.exists
                 (fun (m : Agent_core.Types.message) ->
                    List.exists
                      (function
                        | Agent_core.Types.ToolResult { content; _ } ->
                          String.length content > 10_000
                          && contains ~needle:"END_RESULT_1" content
                          && not (contains ~needle:"[masc:blob" content)
                        | _ -> false)
                      m.content)
                 t.messages)
            restored_turns
        in
        check bool "compact_evicted_messages preserves raw verbatim turn after blob sweep" true has_full_raw
      | Error err -> fail (Keeper_compaction.store_error_to_string err))
   | Ok None -> fail "expected compact_evicted_messages to commit epoch"
   | Error err -> fail (Keeper_compaction.store_error_to_string err));
  (* 5. Provider_context_overflow on remaining turns advances incrementally to epoch 2 *)
  let more_turns =
    ctx_epoch1.retained_turns
    @ [ make_turn ~idx:7 ~user_text:"Finalize deployment" ~tool_name:"Read"
          ~tool_output:(large_output 7) ~assistant_text:"Deployment ready." ]
  in
  let ctx_epoch2 =
    match
      Keeper_compaction.compact_and_project
        ~blob_store
        ~keep_recent_turns:1
        ~force_trigger:(Keeper_compaction.Provider_context_overflow { provider_limit_tokens = Some 32_000 })
        ~on_epoch_committed:(fun a -> committed_epochs := a :: !committed_epochs)
        ~keepers_dir
        ~keeper_id:"keeper-alpha"
        ~measure_message_bytes:msg_bytes
        ~capacity_bytes:18_000
        ~reserved_bytes:1_000
        more_turns
    with
    | Ok c -> c
    | Error err -> fail (Keeper_compaction.store_error_to_string err)
  in
  check bool "epoch 2 committed" true ctx_epoch2.compacted_new_epoch;
  let anchor2 = Option.get ctx_epoch2.anchor in
  check int "epoch_id incremented monotonically to 2" 2 anchor2.epoch_id;
  check bool "epoch 2 preserved prior epoch 1 turn pointers" true
    (List.for_all (fun entry -> List.mem entry anchor2.observations) anchor1.observations);
  (* 6. Runtime_model_input_tail_window pins anchor without static omission preamble *)
  let window_res =
    Runtime_model_input_tail_window.project_with_drop
      ~capacity_bytes:100_000
      ~reserved_bytes:0
      ~measure_message_bytes:msg_bytes
      ctx_epoch2.messages
  in
  (match window_res with
   | Ok proj ->
     check bool "tail window preserved pinned compaction anchor" true
       (match proj.messages with
        | first :: _ -> Runtime_model_input_tail_window.is_compaction_anchor first
        | [] -> false);
     check bool "no static omission preamble injected when anchor is present" false
       (List.exists Runtime_model_input_tail_window.is_synthetic_preamble proj.messages)
   | Error _ -> fail "tail window rejected valid anchored projection");
  (* 7. Concurrent WAL readers + sibling Keeper isolation *)
  Eio.Fiber.all
    [ (fun () ->
         match Keeper_compaction.list_epochs ~keepers_dir ~keeper_id:"keeper-alpha" with
         | Ok epochs -> check int "concurrent reader 1 sees 2 epochs" 2 (List.length epochs)
         | Error err -> fail (Keeper_compaction.store_error_to_string err))
    ; (fun () ->
         match Keeper_compaction.latest_anchor ~keepers_dir ~keeper_id:"keeper-alpha" with
         | Ok (Some a) -> check int "concurrent reader 2 sees epoch 2" 2 a.epoch_id
         | Ok None -> fail "concurrent reader 2 missed epoch"
         | Error err -> fail (Keeper_compaction.store_error_to_string err))
    ; (fun () ->
         let sibling_turns =
           [ make_turn ~idx:1 ~user_text:"Sibling work" ~tool_name:"Read"
               ~tool_output:"small" ~assistant_text:"Sibling done." ]
         in
         match
           Keeper_compaction.compact_and_project
             ~keepers_dir ~keeper_id:"keeper-beta"
             ~measure_message_bytes:msg_bytes
             ~capacity_bytes:10_000 ~reserved_bytes:100 sibling_turns
         with
         | Ok c -> check int "sibling keeper isolated" 1 (List.length c.retained_turns)
         | Error err -> fail (Keeper_compaction.store_error_to_string err))
    ]
;;

let test_capacity_exceeded_and_live_try_provider_wiring () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let pool = Domain_pool.create ~sw ~domain_count:2 (Eio.Stdenv.domain_mgr env) in
  Domain_pool_ref.set pool;
  Fun.protect ~finally:Domain_pool_ref.clear_for_tests @@ fun () ->
  with_temp_dir @@ fun base_path ->
  let keepers_dir = Filename.concat base_path "keepers" in
  Fs_compat.mkdir_p keepers_dir;
  (* 1. Oversized newest turn must return Capacity_exceeded without committing a broken epoch *)
  let huge_turns =
    [ make_turn ~idx:1 ~user_text:"older" ~tool_name:"Read" ~tool_output:"small" ~assistant_text:"done"
    ; make_turn ~idx:2 ~user_text:"newest" ~tool_name:"Read" ~tool_output:(String.make 5000 'z') ~assistant_text:"big"
    ]
  in
  (match
     Keeper_compaction.compact_and_project
       ~keepers_dir
       ~keeper_id:"keeper-overflow"
       ~measure_message_bytes:msg_bytes
       ~capacity_bytes:300
       ~reserved_bytes:50
       huge_turns
   with
   | Error (Keeper_compaction.Capacity_exceeded _) -> ()
   | Error other ->
     fail ("expected Capacity_exceeded, got: " ^ Keeper_compaction.store_error_to_string other)
   | Ok _ -> fail "expected Capacity_exceeded when newest turn exceeds capacity");
  (match Keeper_compaction.latest_anchor ~keepers_dir ~keeper_id:"keeper-overflow" with
   | Ok None -> ()
   | Ok (Some _) -> fail "Capacity_exceeded must not commit a broken epoch"
   | Error err -> fail (Keeper_compaction.store_error_to_string err));
  (* 2. compact_evicted_messages commits idempotently + fires global on_epoch_committed hook *)
  let hook_epochs = ref [] in
  Keeper_compaction.set_on_epoch_committed
    (Some (fun ~keepers_dir:_ ~keeper_id anchor -> hook_epochs := (keeper_id, anchor.epoch_id) :: !hook_epochs));
  Fun.protect
    ~finally:(fun () -> Keeper_compaction.set_on_epoch_committed None)
    (fun () ->
       let t1 = make_turn ~idx:1 ~user_text:"Step one" ~tool_name:"Read" ~tool_output:"ok1" ~assistant_text:"Done 1" in
       let t2 = make_turn ~idx:2 ~user_text:"Step two" ~tool_name:"Read" ~tool_output:"ok2" ~assistant_text:"Done 2" in
       let evicted = t1.messages @ t2.messages in
       let anchor =
         match
           Keeper_compaction.compact_evicted_messages
             ~keepers_dir
             ~keeper_id:"keeper-live"
             ~trigger:(Keeper_compaction.Provider_context_overflow { provider_limit_tokens = None })
             ~evicted_messages:evicted
             ()
         with
         | Ok (Some a) -> a
         | Ok None -> fail "expected committed anchor from evicted messages"
         | Error err -> fail (Keeper_compaction.store_error_to_string err)
       in
       check int "global hook received epoch 1" 1 (List.length !hook_epochs);
       (* Re-running on exact same evicted prefix is idempotent (Ok None) *)
       (match
          Keeper_compaction.compact_evicted_messages
            ~keepers_dir
            ~keeper_id:"keeper-live"
            ~trigger:(Keeper_compaction.Provider_context_overflow { provider_limit_tokens = None })
            ~evicted_messages:evicted
            ()
        with
        | Ok None -> ()
        | Ok (Some _) -> fail "duplicate eviction should be idempotent"
        | Error err -> fail (Keeper_compaction.store_error_to_string err));
       (* 3. Live Keeper_turn_driver_try_provider projection pins anchor_to_message *)
       let t3 = make_turn ~idx:3 ~user_text:"Current turn" ~tool_name:"Read" ~tool_output:"ok3" ~assistant_text:"Done 3" in
       let full_history = evicted @ t3.messages in
       let digest_at = Runtime_model_input_tail_window.atom_opening_digest full_history in
       let composed =
         Keeper_turn_driver_try_provider.For_testing.compose_carried_model_input
           ~compaction_anchor:anchor
           ~measure_message_bytes:msg_bytes
           ~measure_wire_bytes:(fun m -> Some (msg_bytes m))
           ~front:None
           ~accepted:None
           ~history_digest_at:digest_at
           ~current_turn_results:Current_turn_verbatim
           ~base_path:""
           ~turn_boundary:(Keeper_carried_front.Turn_boundary { end_atom = 2 })
           full_history
       in
       check bool "try_provider pins compaction anchor message ahead of retained tail" true
         (List.exists Runtime_model_input_tail_window.is_compaction_anchor
            composed.projection.Runtime_model_input_tail_window.messages))
;;

let test_multi_epoch_bounded_anchor_rolloff_and_lossless_recall () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let pool = Domain_pool.create ~sw ~domain_count:2 (Eio.Stdenv.domain_mgr env) in
  Domain_pool_ref.set pool;
  Fun.protect ~finally:Domain_pool_ref.clear_for_tests @@ fun () ->
  with_temp_dir @@ fun base_path ->
  let keepers_dir = Server_tool_blob_scope.scope.config_keepers_dir ~base_path in
  Fs_compat.mkdir_p keepers_dir;
  let capacity_bytes = 6_000 in
  let reserved_bytes = 500 in
  let expected_anchor_ceiling =
    Keeper_compaction.anchor_budget_for_window ~capacity_bytes ~reserved_bytes
  in
  let total_epochs = 60 in
  let retained = ref [] in
  let last_anchor = ref None in
  for epoch = 1 to total_epochs do
    let new_turn =
      make_turn
        ~idx:epoch
        ~user_text:(Printf.sprintf "Long-horizon milestone %03d: inspect and verify module_%d." epoch epoch)
        ~tool_name:"Read"
        ~tool_output:(Printf.sprintf "OUTPUT_EPOCH_%03d_%s" epoch (String.make 1_400 'r'))
        ~assistant_text:
          (Printf.sprintf
             "Decision %03d: verified invariants for src/mod_%d.ml and recorded rollout note."
             epoch
             epoch)
    in
    let turns =
      match !retained with
      | [] ->
        [ make_turn ~idx:0 ~user_text:"Bootstrap workspace" ~tool_name:"Read"
            ~tool_output:(Printf.sprintf "OUTPUT_EPOCH_000_%s" (String.make 1_400 'b'))
            ~assistant_text:"Decision 000: workspace initialized."
        ; new_turn
        ]
      | prev -> prev @ [ new_turn ]
    in
    let ctx =
      match
        Keeper_compaction.compact_and_project
          ~keep_recent_turns:1
          ~force_trigger:(Keeper_compaction.Explicit_hard_limit { capacity_bytes; observed_bytes = capacity_bytes + 500 })
          ~keepers_dir
          ~keeper_id:"keeper-long-horizon"
          ~measure_message_bytes:msg_bytes
          ~capacity_bytes
          ~reserved_bytes
          turns
      with
      | Ok c -> c
      | Error err ->
        fail
          (Printf.sprintf "epoch %d failed unexpectedly: %s" epoch
             (Keeper_compaction.store_error_to_string err))
    in
    check bool (Printf.sprintf "epoch %d committed" epoch) true ctx.compacted_new_epoch;
    let anchor =
      match ctx.anchor with
      | Some a -> a
      | None -> fail (Printf.sprintf "epoch %d missing anchor" epoch)
    in
    check int (Printf.sprintf "epoch_id=%d" epoch) epoch anchor.epoch_id;
    let anchor_bytes = msg_bytes (Keeper_compaction.anchor_to_message anchor) in
    check bool
      (Printf.sprintf "epoch %d anchor bytes (%d) <= structural budget (%d)" epoch anchor_bytes expected_anchor_ceiling)
      true
      (anchor_bytes <= expected_anchor_ceiling);
    retained := ctx.retained_turns;
    last_anchor := Some anchor
  done;
  let final_anchor = Option.get !last_anchor in
  check bool "roll-off recorded archived_epochs_through" true
    (Option.is_some final_anchor.archived_epochs_through);
  (* All 60 immutable epochs are persisted in SQLite, and epoch 1's earliest rolled-off
     turn remains 100% losslessly retrievable verbatim! *)
  (match Keeper_compaction.list_epochs ~keepers_dir ~keeper_id:"keeper-long-horizon" with
   | Ok epochs -> check int "all 60 epochs persisted immutably" total_epochs (List.length epochs)
   | Error err -> fail (Keeper_compaction.store_error_to_string err));
  (match
     Keeper_compaction.load_archived_turn
       ~keepers_dir
       ~keeper_id:"keeper-long-horizon"
       ~turn_id:(Ids.Turn_id.of_string "turn-000")
   with
   | Ok (Some restored) ->
     let has_epoch0_payload =
       List.exists
         (fun (m : Agent_core.Types.message) ->
            List.exists
              (function
                | Agent_core.Types.ToolResult { content; _ } ->
                  contains ~needle:"OUTPUT_EPOCH_000_" content
                | _ -> false)
              m.content)
         restored.messages
     in
     check bool "earliest rolled-off turn-000 losslessly retrievable verbatim" true has_epoch0_payload
   | Ok None -> fail "earliest rolled-off turn-000 missing from SQLite archive"
   | Error err -> fail (Keeper_compaction.store_error_to_string err));
  (* Also verify compact_evicted_messages bounds anchor growth across 40 epochs under Explicit_hard_limit *)
  let ev_cap = 4_000 in
  let ev_ceiling = Keeper_compaction.anchor_budget_for_window ~capacity_bytes:ev_cap ~reserved_bytes:0 in
  let ev_history = ref [] in
  for idx = 1 to 40 do
    let t =
      make_turn
        ~idx
        ~user_text:(Printf.sprintf "Runtime eviction milestone %03d" idx)
        ~tool_name:"Read"
        ~tool_output:(Printf.sprintf "EVICTED_RAW_%03d" idx)
        ~assistant_text:
          (Printf.sprintf "Concluded runtime step %03d with verified trace note." idx)
    in
    ev_history := !ev_history @ t.messages;
    match
      Keeper_compaction.compact_evicted_messages
        ~keepers_dir
        ~keeper_id:"keeper-evicted-bounded"
        ~trigger:(Keeper_compaction.Explicit_hard_limit { capacity_bytes = ev_cap; observed_bytes = ev_cap + 1000 })
        ~evicted_messages:!ev_history
        ()
    with
    | Ok (Some a) ->
      let sz = msg_bytes (Keeper_compaction.anchor_to_message a) in
      check bool
        (Printf.sprintf "compact_evicted_messages epoch %d bytes (%d) <= %d" idx sz ev_ceiling)
        true
        (sz <= ev_ceiling)
    | Ok None -> fail (Printf.sprintf "expected epoch %d commit" idx)
    | Error err -> fail (Keeper_compaction.store_error_to_string err)
  done;
  (* Provider switch from larger anchor down to tight capacity projects seamlessly *)
  let small_turn =
    [ make_turn ~idx:99 ~user_text:"Quick follow-up" ~tool_name:"Read"
        ~tool_output:"ok" ~assistant_text:"ack" ]
  in
  let tight_cap = 1_600 in
  let tight_step =
    Keeper_compaction.project_for_provider
      ~anchor:(Some final_anchor)
      ~measure_message_bytes:msg_bytes
      ~capacity_bytes:tight_cap
      ~reserved_bytes:100
      small_turn
  in
  match tight_step with
  | Keeper_compaction.Fits_verbatim { anchor = Some projected; _ } ->
    let sz = msg_bytes (Keeper_compaction.anchor_to_message projected) in
    let tight_budget =
      Keeper_compaction.anchor_budget_for_window ~capacity_bytes:tight_cap ~reserved_bytes:100
    in
    check bool "provider switch down bounds projected anchor" true (sz <= tight_budget)
  | _ -> fail "expected tighter provider switch to bound projected anchor and fit verbatim"
;;

let test_microcompaction_durable_blobs_protected_from_sweep () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let pool = Domain_pool.create ~sw ~domain_count:2 (Eio.Stdenv.domain_mgr env) in
  Domain_pool_ref.set pool;
  Fun.protect ~finally:Domain_pool_ref.clear_for_tests @@ fun () ->
  with_temp_dir @@ fun base_path ->
  let keepers_dir = Server_tool_blob_scope.scope.config_keepers_dir ~base_path in
  Fs_compat.mkdir_p keepers_dir;
  let blob_store = Tool_blob_store.create ~base_path in
  let large_output idx =
    Printf.sprintf "SWEEP_PROTECTED_HEAD_%d\n%s\nSWEEP_PROTECTED_TAIL_%d" idx (String.make 10_000 'q') idx
  in
  let turns =
    List.init 6 (fun i ->
      make_turn
        ~idx:(i + 1)
        ~user_text:(Printf.sprintf "Sweep check turn %d" (i + 1))
        ~tool_name:"Read"
        ~tool_output:(large_output (i + 1))
        ~assistant_text:(Printf.sprintf "Checked %d" (i + 1)))
  in
  let ctx =
    match
      Keeper_compaction.compact_and_project
        ~blob_store
        ~keep_recent_turns:2
        ~keepers_dir
        ~keeper_id:"keeper-sweep-root"
        ~measure_message_bytes:msg_bytes
        ~capacity_bytes:50_000
        ~reserved_bytes:1_000
        turns
    with
    | Ok c -> c
    | Error err -> fail (Keeper_compaction.store_error_to_string err)
  in
  check int "4 microcompacted durable blobs created" 4 ctx.microcompacted_results;
  let run_sweep mode =
    match Tool_blob_maintenance.run ~base_path ~scope:Server_tool_blob_scope.scope ~mode with
    | Ok report -> report
    | Error err -> fail (Tool_blob_maintenance.error_to_string err)
  in
  let first = run_sweep Tool_blob_maintenance.Observe_only in
  check (list string) "compaction WAL and sidecars have zero unclassified files" [] first.unclassified;
  check bool "live_references includes all 4 active microcompacted blobs" true (first.live_references >= 4);
  check int "zero candidates recorded for active microcompacted blobs" 0 first.candidates_recorded;
  let second = run_sweep Tool_blob_maintenance.Delete_previous_candidates in
  check (list string) "delete sweep has zero unclassified files" [] second.unclassified;
  check int "zero active microcompacted blobs deleted" 0 second.deleted;
  let third = run_sweep Tool_blob_maintenance.Observe_only in
  check int "second observe still sees zero candidates" 0 third.candidates_recorded;
  let fourth = run_sweep Tool_blob_maintenance.Delete_previous_candidates in
  check int "second delete still deletes zero active blobs" 0 fourth.deleted;
  (* Verify every structured handle in projected messages still fetches verbatim *)
  let verified_handles = ref 0 in
  List.iter
    (fun (msg : Agent_core.Types.message) ->
       List.iter
         (function
           | Agent_core.Types.ToolResult { content; _ } ->
             (match Tool_output.decode_structured_handle content with
              | Tool_output.Decoded ref_ ->
                (match Tool_blob_store.fetch blob_store ~sha256:ref_.sha256 with
                 | Ok (Some bytes) ->
                   check int "surviving blob exact byte length" ref_.bytes (String.length bytes);
                   incr verified_handles
                 | Ok None -> fail "sweep deleted an active microcompacted blob"
                 | Error err -> fail (Tool_blob_store.fetch_error_to_string err))
              | Tool_output.Not_marker | Tool_output.Invalid_marker _ -> ())
           | _ -> ())
         msg.content)
    ctx.messages;
  check int "all 4 microcompacted handles survived sweep verbatim" 4 !verified_handles
;;

let test_canonical_turn_store_compaction_watermark_and_failover () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let pool = Domain_pool.create ~sw ~domain_count:2 (Eio.Stdenv.domain_mgr env) in
  Domain_pool_ref.set pool;
  Fun.protect ~finally:Domain_pool_ref.clear_for_tests @@ fun () ->
  with_temp_dir @@ fun base_path ->
  let keepers_dir = Server_tool_blob_scope.scope.config_keepers_dir ~base_path in
  Fs_compat.mkdir_p keepers_dir;
  let keeper_id = "keeper-e2-regression" in
  let module C = Keeper_canonical_turn_store in
  let require_c = function
    | Ok v -> v
    | Error err -> fail (C.store_error_to_string err)
  in
  (* 1. Fail-closed validation: blank turn_id & self-cycle parent_turn_id rejected. *)
  (match
     C.commit_turn
       ~keepers_dir ~keeper_id
       ~turn_id:(Ids.Turn_id.of_string "   ")
       ~runtime_kind:C.Agent_core_http ~runtime_id:"glm:1"
       ~user_input:"hi" ~tool_calls_json:(`List []) ~assistant_output:"ok"
       ~usage_json:(`Assoc []) ~created_at:1.0 ()
   with
   | Error (C.Corrupt_record _) -> ()
   | Error err -> fail (C.store_error_to_string err)
   | Ok _ -> fail "blank turn_id must fail closed");
  let t1_id = Ids.Turn_id.of_string "trace-e2:1" in
  let t2_id = Ids.Turn_id.of_string "acp:sess-1:2" in
  let t3_id = Ids.Turn_id.of_string "trace-e2:3" in
  (match
     C.commit_turn
       ~keepers_dir ~keeper_id ~parent_turn_id:t1_id ~turn_id:t1_id
       ~runtime_kind:C.Agent_core_http ~runtime_id:"glm:1"
       ~user_input:"hi" ~tool_calls_json:(`List []) ~assistant_output:"ok"
       ~usage_json:(`Assoc []) ~created_at:1.0 ()
   with
   | Error (C.Corrupt_record _) -> ()
   | Error err -> fail (C.store_error_to_string err)
   | Ok _ -> fail "self-referencing parent_turn_id must fail closed");
  (* 2. Commit HTTP Turn 1, ACP Turn 2, HTTP Turn 3. *)
  let t1 =
    C.commit_turn ~keepers_dir ~keeper_id ~turn_id:t1_id
      ~runtime_kind:C.Agent_core_http ~runtime_id:"glm:1"
      ~user_input:"Inspect schema registry"
      ~tool_calls_json:(`List [])
      ~assistant_output:"HTTP Turn 1 completed schema audit."
      ~usage_json:(`Assoc []) ~created_at:10.0 ()
    |> require_c
  in
  let t2 =
    C.commit_turn ~keepers_dir ~keeper_id ~turn_id:t2_id
      ~runtime_kind:C.Acp_cli ~runtime_id:"antigravity_acp:opus"
      ~user_input:"Verify ACP failover"
      ~tool_calls_json:(`List [])
      ~assistant_output:"ACP Turn 2 completed failover check."
      ~usage_json:(`Assoc []) ~created_at:20.0 ()
    |> require_c
  in
  let _t3 =
    C.commit_turn ~keepers_dir ~keeper_id ~turn_id:t3_id
      ~runtime_kind:C.Agent_core_http ~runtime_id:"glm:1"
      ~user_input:"Post-eviction retained turn"
      ~tool_calls_json:(`List [])
      ~assistant_output:"HTTP Turn 3 stays retained verbatim."
      ~usage_json:(`Assoc []) ~created_at:30.0 ()
    |> require_c
  in
  (* 3. ON CONFLICT idempotent re-commit of older t1 with parent_turn_id:None
        MUST preserve t1's original parent (None), NEVER creating a forward cycle to t3! *)
  let t1_rewritten =
    C.commit_turn ~keepers_dir ~keeper_id ~turn_id:t1_id
      ~runtime_kind:C.Agent_core_http ~runtime_id:"glm:1"
      ~user_input:"Inspect schema registry"
      ~tool_calls_json:(`List [])
      ~assistant_output:"HTTP Turn 1 completed schema audit."
      ~usage_json:(`Assoc [ "input_tokens", `Int 42 ]) ~created_at:11.0 ()
    |> require_c
  in
  check (option string) "re-committing older t1 preserves original parent (None)" None
    (Option.map Ids.Turn_id.to_string t1_rewritten.parent_turn_id);
  (* 4. Production Keeper_compaction.compact_evicted_messages (which mints
        atom-<idx>-<hex16> covers_through_turn) over raw messages of Turn 1 + Turn 2
        records exact durable compaction watermark cutting off seq <= 2 while
        retaining un-evicted Turn 3! *)
  let plain_msg role text : Agent_core.Types.message =
    { origin = Agent_core.Llm_provider.Types.Conversation
    ; role
    ; content = [ Agent_core.Types.Text text ]
    ; name = None
    ; tool_call_id = None
    ; metadata = []
    }
  in
  let evicted_raw_messages =
    [ plain_msg User t1.user_input
    ; plain_msg Assistant t1.assistant_output
    ; plain_msg User t2.user_input
    ; plain_msg Assistant t2.assistant_output
    ]
  in
  let anchor =
    match
      Keeper_compaction.compact_evicted_messages
        ~keepers_dir
        ~keeper_id
        ~trigger:(Keeper_compaction.Explicit_hard_limit { capacity_bytes = 64_000; observed_bytes = 70_000 })
        ~evicted_messages:evicted_raw_messages
        ()
    with
    | Ok (Some a) -> a
    | Ok None -> fail "expected compact_evicted_messages to commit an anchor"
    | Error err -> fail (Keeper_compaction.store_error_to_string err)
  in
  check bool "production anchor uses atom-<idx>-<hex16> id" true
    (String.starts_with ~prefix:"atom-" (Ids.Turn_id.to_string anchor.covers_through_turn));
  let handoff = C.load_handoff_context ~keepers_dir ~keeper_id |> require_c in
  check (list string) "load_handoff_context excludes compacted T1 & T2 and retains only T3"
    [ "trace-e2:3" ]
    (List.map (fun (t : C.canonical_turn) -> Ids.Turn_id.to_string t.turn_id)
       handoff.turns_after_anchor);
  (* 5. Bidirectional hydration deduplication:
        - Cold start (existing_messages = []) hydrates [anchor; T3]
        - Stale checkpoint containing T3 already hydrates [] (zero duplication)
        - Stale checkpoint containing T3 + newer ACP Turn 4 hydrates ONLY [T4]! *)
  let t4_id = Ids.Turn_id.of_string "acp:sess-2:4" in
  let _t4 =
    C.commit_turn ~keepers_dir ~keeper_id ~turn_id:t4_id
      ~runtime_kind:C.Acp_cli ~runtime_id:"antigravity_acp:opus"
      ~user_input:"New ACP turn after stale HTTP checkpoint"
      ~tool_calls_json:(`List [])
      ~assistant_output:"ACP Turn 4 must hydrate onto stale T3 checkpoint without duplicating T3."
      ~usage_json:(`Assoc []) ~created_at:40.0 ()
    |> require_c
  in
  let stale_http_checkpoint_msgs =
    [ plain_msg User "Post-eviction retained turn"
    ; plain_msg Assistant "HTTP Turn 3 stays retained verbatim."
    ]
  in
  let hydrated_onto_stale =
    C.hydrate_missing_turns ~keepers_dir ~keeper_id ~existing_messages:stale_http_checkpoint_msgs
    |> require_c
  in
  let hydrated_text =
    hydrated_onto_stale
    |> List.concat_map (fun (m : Agent_core.Types.message) ->
      List.filter_map (function Agent_core.Types.Text s -> Some s | _ -> None) m.content)
    |> String.concat "\n"
  in
  check bool "stale checkpoint hydrates missing ACP T4" true
    (contains ~needle:"ACP Turn 4 must hydrate" hydrated_text);
  check bool "stale checkpoint does NOT duplicate already-present T3" false
    (contains ~needle:"HTTP Turn 3 stays retained verbatim." hydrated_text);
  (* 6. Operator history clear (record_history_reset): pre-clear anchor AND
        pre-clear turns are NEVER resurrected on empty or [System]-only
        checkpoints, and post-reset turns start a fresh parent chain! *)
  C.record_history_reset ~keepers_dir ~keeper_id |> require_c;
  let post_clear_empty =
    C.hydrate_missing_turns ~keepers_dir ~keeper_id ~existing_messages:[] |> require_c
  in
  check int "after history reset, empty checkpoint hydrates 0 messages" 0
    (List.length post_clear_empty);
  let system_only =
    [ { (plain_msg System "standing system prompt") with
        origin = Agent_core.Llm_provider.Types.System_context
      }
    ]
  in
  let post_clear_sys =
    C.hydrate_missing_turns ~keepers_dir ~keeper_id ~existing_messages:system_only |> require_c
  in
  check int "after history reset, [System]-only checkpoint hydrates 0 messages" 0
    (List.length post_clear_sys);
  let t5_id = Ids.Turn_id.of_string "trace-post-reset#1" in
  let t5 =
    C.commit_turn ~keepers_dir ~keeper_id ~turn_id:t5_id
      ~runtime_kind:C.Agent_core_http ~runtime_id:"glm:1"
      ~user_input:"Fresh turn after operator history clear"
      ~tool_calls_json:(`List [])
      ~assistant_output:"Post-reset continuity works cleanly."
      ~usage_json:(`Assoc []) ~created_at:50.0 ()
    |> require_c
  in
  check (option string) "first post-reset turn starts a fresh parent chain (None)" None
    (Option.map Ids.Turn_id.to_string t5.parent_turn_id);
  let post_reset_handoff = C.load_handoff_context ~keepers_dir ~keeper_id |> require_c in
  check bool "pre-reset compaction anchor suppressed after reset" true
    (Option.is_none post_reset_handoff.anchor);
  check (list string) "only post-reset turns circulate" [ "trace-post-reset#1" ]
    (List.map (fun (t : C.canonical_turn) -> Ids.Turn_id.to_string t.turn_id)
       post_reset_handoff.turns_after_anchor)
;;

let test_canonical_turn_hydration_edge_cases () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let pool = Domain_pool.create ~sw ~domain_count:2 (Eio.Stdenv.domain_mgr env) in
  Domain_pool_ref.set pool;
  Fun.protect ~finally:Domain_pool_ref.clear_for_tests @@ fun () ->
  with_temp_dir @@ fun base_path ->
  let keepers_dir = Server_tool_blob_scope.scope.config_keepers_dir ~base_path in
  Fs_compat.mkdir_p keepers_dir;
  let module C = Keeper_canonical_turn_store in
  let require_c = function
    | Ok v -> v
    | Error err -> fail (C.store_error_to_string err)
  in
  let plain_msg ?(metadata = []) role blocks : Agent_core.Types.message =
    { origin = Agent_core.Llm_provider.Types.Conversation
    ; role
    ; content = blocks
    ; name = None
    ; tool_call_id = None
    ; metadata
    }
  in
  let extract_text msgs =
    msgs
    |> List.concat_map (fun (m : Agent_core.Types.message) ->
      List.filter_map (function Agent_core.Types.Text s -> Some s | _ -> None) m.content)
    |> String.concat "\n"
  in
  (* (a) Suppressed terminal-effect turn (assistant_output = "") + ACP bind_turn_ref:
         checkpoint has User + ToolUse-only Assistant (no Text); zero duplication/resurrection! *)
  let k_sup = "keeper-suppressed" in
  ignore
    (C.commit_turn ~keepers_dir ~keeper_id:k_sup
       ~turn_id:(Ids.Turn_id.of_string "acp-raw-uuid-1")
       ~runtime_kind:C.Acp_cli ~runtime_id:"agy:opus"
       ~user_input:"Post board update"
       ~tool_calls_json:(`List [ `Assoc [ "tool_name", `String "board_post" ] ])
       ~assistant_output:"Suppressed narration that must never resurrect"
       ~usage_json:(`Assoc []) ~created_at:10.0 ()
     |> require_c);
  C.bind_turn_ref ~keepers_dir ~keeper_id:k_sup
    ~from_turn_id:(Ids.Turn_id.of_string "acp-raw-uuid-1")
    ~to_turn_id:(Ids.Turn_id.of_string "trace-sup#1")
    ~suppress_assistant_output:true
    ()
  |> require_c;
  let bridged_sup_msgs =
    [ plain_msg ~metadata:[ "masc.bridged_turn_ref", `String "trace-sup#1" ] User
        [ Agent_core.Types.Text "Post board update" ]
    ; plain_msg ~metadata:[ "masc.bridged_turn_ref", `String "trace-sup#1" ] Assistant
        [ Agent_core.Types.ToolUse { id = "tc1"; name = "board_post"; input = `Assoc [] } ]
    ]
  in
  let hydrated_sup =
    C.hydrate_missing_turns ~keepers_dir ~keeper_id:k_sup ~existing_messages:bridged_sup_msgs
    |> require_c
  in
  check int "suppressed bridged turn hydrates 0 duplicates" 0 (List.length hydrated_sup);
  (* Even on cold start without existing_messages, suppressed prose is blank (never resurrected). *)
  let cold_sup =
    C.hydrate_missing_turns ~keepers_dir ~keeper_id:k_sup ~existing_messages:[] |> require_c
  in
  check bool "suppressed prose never resurrected on cold start" false
    (contains ~needle:"Suppressed narration" (extract_text cold_sup));
  (* (b) Multi-Text-block Assistant message matches joined text_of_content without duplication! *)
  let k_multi = "keeper-multiblock" in
  ignore
    (C.commit_turn ~keepers_dir ~keeper_id:k_multi
       ~turn_id:(Ids.Turn_id.of_string "trace-multi#1")
       ~runtime_kind:C.Agent_core_http ~runtime_id:"glm:1"
       ~user_input:"Summarize two parts"
       ~tool_calls_json:(`List [])
       ~assistant_output:"First paragraph.\nSecond paragraph."
       ~usage_json:(`Assoc []) ~created_at:20.0 ()
     |> require_c);
  let legacy_multiblock_ckpt =
    [ plain_msg User [ Agent_core.Types.Text "Summarize two parts" ]
    ; plain_msg Assistant
        [ Agent_core.Types.Text "First paragraph."
        ; Agent_core.Types.Text "Second paragraph."
        ]
    ]
  in
  let hydrated_multi =
    C.hydrate_missing_turns ~keepers_dir ~keeper_id:k_multi
      ~existing_messages:legacy_multiblock_ckpt
    |> require_c
  in
  check int "multi-Text-block legacy checkpoint matches joined assistant_output (0 duplicates)" 0
    (List.length hydrated_multi);
  (* (c) Repeated identical autonomous prompts across T1 (HTTP checkpointed),
         T2 (distinct ACP), and T3 (repeated identical prompt/reply as T1):
         - Hydration MUST return BOTH T2 and T3 (never jumping cursor to T3)!
         - Compaction evicting ONLY T1 MUST set cutoff_seq = 1, keeping T2 and T3! *)
  let k_rep = "keeper-repeated-wake" in
  let wake_prompt = "Check inbox and board." in
  let wake_reply = "All clear." in
  ignore
    (C.commit_turn ~keepers_dir ~keeper_id:k_rep
       ~turn_id:(Ids.Turn_id.of_string "trace-rep#1")
       ~runtime_kind:C.Agent_core_http ~runtime_id:"glm:1"
       ~user_input:wake_prompt ~tool_calls_json:(`List []) ~assistant_output:wake_reply
       ~usage_json:(`Assoc []) ~created_at:10.0 ()
     |> require_c);
  ignore
    (C.commit_turn ~keepers_dir ~keeper_id:k_rep
       ~turn_id:(Ids.Turn_id.of_string "trace-rep#2")
       ~runtime_kind:C.Acp_cli ~runtime_id:"agy:opus"
       ~user_input:"Investigate ACP failover"
       ~tool_calls_json:(`List []) ~assistant_output:"ACP Turn 2 unique result."
       ~usage_json:(`Assoc []) ~created_at:20.0 ()
     |> require_c);
  ignore
    (C.commit_turn ~keepers_dir ~keeper_id:k_rep
       ~turn_id:(Ids.Turn_id.of_string "trace-rep#3")
       ~runtime_kind:C.Acp_cli ~runtime_id:"agy:opus"
       ~user_input:wake_prompt ~tool_calls_json:(`List []) ~assistant_output:wake_reply
       ~usage_json:(`Assoc []) ~created_at:30.0 ()
     |> require_c);
  let legacy_t1_only =
    [ plain_msg User [ Agent_core.Types.Text wake_prompt ]
    ; plain_msg Assistant [ Agent_core.Types.Text wake_reply ]
    ]
  in
  let hydrated_rep =
    C.hydrate_missing_turns ~keepers_dir ~keeper_id:k_rep ~existing_messages:legacy_t1_only
    |> require_c
  in
  let hydrated_rep_ids =
    hydrated_rep
    |> List.filter_map (fun (m : Agent_core.Types.message) ->
      if m.role = User
      then
        match List.assoc_opt C.canonical_turn_id_metadata_key m.metadata with
        | Some (`String s) -> Some s
        | _ -> None
      else None)
  in
  check (list string) "repeated wake prompt hydrates BOTH T2 and T3 (never skips T2)"
    [ "trace-rep#2"; "trace-rep#3" ]
    hydrated_rep_ids;
  (* Compaction evicting ONLY T1's messages cuts off at seq 1, retaining T2 and T3! *)
  (match
     Keeper_compaction.compact_evicted_messages
       ~keepers_dir ~keeper_id:k_rep
       ~trigger:(Keeper_compaction.Explicit_hard_limit { capacity_bytes = 64_000; observed_bytes = 70_000 })
       ~evicted_messages:legacy_t1_only
       ()
   with
   | Ok (Some _) -> ()
   | Ok None -> fail "expected compaction anchor for T1"
   | Error err -> fail (Keeper_compaction.store_error_to_string err));
  let handoff_rep = C.load_handoff_context ~keepers_dir ~keeper_id:k_rep |> require_c in
  check (list string) "compacting only T1 preserves both T2 and repeated-prompt T3"
    [ "trace-rep#2"; "trace-rep#3" ]
    (List.map (fun (t : C.canonical_turn) -> Ids.Turn_id.to_string t.turn_id)
       handoff_rep.turns_after_anchor)
;;

let test_canonical_turn_multi_epoch_watermark_monotonicity () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let pool = Domain_pool.create ~sw ~domain_count:2 (Eio.Stdenv.domain_mgr env) in
  Domain_pool_ref.set pool;
  Fun.protect ~finally:Domain_pool_ref.clear_for_tests @@ fun () ->
  with_temp_dir @@ fun base_path ->
  let keepers_dir = Server_tool_blob_scope.scope.config_keepers_dir ~base_path in
  Fs_compat.mkdir_p keepers_dir;
  let module C = Keeper_canonical_turn_store in
  let require_c = function
    | Ok v -> v
    | Error err -> fail (C.store_error_to_string err)
  in
  let plain_msg role content : Agent_core.Types.message =
    { origin = Agent_core.Llm_provider.Types.Conversation
    ; role
    ; content
    ; name = None
    ; tool_call_id = None
    ; metadata = []
    }
  in
  let keeper_id = "multi-epoch-keeper" in
  let wake_prompt = "Routine autonomous check." in
  let wake_reply = "Everything green." in
  let commit id kind prompt reply ts =
    ignore
      (C.commit_turn
         ~keepers_dir
         ~keeper_id
         ~turn_id:(Ids.Turn_id.of_string id)
         ~runtime_kind:kind
         ~runtime_id:"runtime:1"
         ~user_input:prompt
         ~tool_calls_json:(`List [])
         ~assistant_output:reply
         ~usage_json:(`Assoc [])
         ~created_at:ts
         ()
       |> require_c)
  in
  commit "trace-me#1" C.Agent_core_http wake_prompt wake_reply 10.0;
  commit "trace-me#2" C.Acp_cli "Fix queue backpressure" "Applied bounded queue" 20.0;
  commit "trace-me#3" C.Acp_cli wake_prompt wake_reply 30.0;
  commit "trace-me#4" C.Agent_core_http "Live follow-up question" "Live answer" 40.0;
  let compact evicted_messages =
    match
      Keeper_compaction.compact_evicted_messages
        ~keepers_dir
        ~keeper_id
        ~trigger:(Keeper_compaction.Explicit_hard_limit { capacity_bytes = 64_000; observed_bytes = 70_000 })
        ~evicted_messages
        ()
    with
    | Ok (Some anchor) -> anchor
    | Ok None -> fail "expected compaction anchor"
    | Error err -> fail (Keeper_compaction.store_error_to_string err)
  in
  (* Epoch 1 compacts legacy untagged [T1, T2] -> cutoff_seq = 2. *)
  let a1 =
    compact
      [ plain_msg User [ Agent_core.Types.Text wake_prompt ]
      ; plain_msg Assistant [ Agent_core.Types.Text wake_reply ]
      ; plain_msg User [ Agent_core.Types.Text "Fix queue backpressure" ]
      ; plain_msg Assistant [ Agent_core.Types.Text "Applied bounded queue" ]
      ]
  in
  check int "epoch 1" 1 a1.epoch_id;
  let h1 = C.load_handoff_context ~keepers_dir ~keeper_id |> require_c in
  check (list string) "after epoch 1 only T3 and T4 remain"
    [ "trace-me#3"; "trace-me#4" ]
    (List.map (fun (t : C.canonical_turn) -> Ids.Turn_id.to_string t.turn_id) h1.turns_after_anchor);
  (* Epoch 2 compacts legacy untagged [T3], which repeats T1's exact prompt & reply.
     Must match seq 3 (NOT regress to seq 1!) and never resurrect T2 or T3. *)
  let a2 =
    compact
      [ plain_msg User [ Agent_core.Types.Text wake_prompt ]
      ; plain_msg Assistant [ Agent_core.Types.Text wake_reply ]
      ]
  in
  check int "epoch 2" 2 a2.epoch_id;
  let h2 = C.load_handoff_context ~keepers_dir ~keeper_id |> require_c in
  check (list string) "after epoch 2 repeated-prompt T3 advances cutoff to 3 (only T4 remains)"
    [ "trace-me#4" ]
    (List.map (fun (t : C.canonical_turn) -> Ids.Turn_id.to_string t.turn_id) h2.turns_after_anchor);
  (* Epoch 3 compacts an unmapped legacy turn absent from .canonical-turns.db.
     Even with no watermark row for epoch 3, load_handoff_context must honor
     prior epochs' MAX(cutoff_seq) = 3 and never resurrect T1, T2, or T3. *)
  let a3 =
    compact
      [ plain_msg User [ Agent_core.Types.Text "Unmapped historical prompt" ]
      ; plain_msg Assistant [ Agent_core.Types.Text "Unmapped historical reply" ]
      ]
  in
  check int "epoch 3" 3 a3.epoch_id;
  let h3 = C.load_handoff_context ~keepers_dir ~keeper_id |> require_c in
  check (list string) "after epoch 3 unmapped eviction still preserves floor cutoff (only T4 remains)"
    [ "trace-me#4" ]
    (List.map (fun (t : C.canonical_turn) -> Ids.Turn_id.to_string t.turn_id) h3.turns_after_anchor);
  (* New post-epoch-3 turn T5 appears cleanly alongside T4. *)
  commit "trace-me#5" C.Acp_cli "Post-epoch-3 ACP turn" "Post-epoch-3 reply" 50.0;
  let h4 = C.load_handoff_context ~keepers_dir ~keeper_id |> require_c in
  check (list string) "post-epoch-3 commit appends T5 after T4 without resurrecting T1..T3"
    [ "trace-me#4"; "trace-me#5" ]
    (List.map (fun (t : C.canonical_turn) -> Ids.Turn_id.to_string t.turn_id) h4.turns_after_anchor)
;;

let test_canonical_turn_disk_lifecycle_prune_and_delete () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let pool = Domain_pool.create ~sw ~domain_count:2 (Eio.Stdenv.domain_mgr env) in
  Domain_pool_ref.set pool;
  Fun.protect ~finally:Domain_pool_ref.clear_for_tests @@ fun () ->
  with_temp_dir @@ fun base_path ->
  let keepers_dir = Server_tool_blob_scope.scope.config_keepers_dir ~base_path in
  Fs_compat.mkdir_p keepers_dir;
  let module C = Keeper_canonical_turn_store in
  let require_c = function
    | Ok v -> v
    | Error err -> fail (C.store_error_to_string err)
  in
  let plain_msg role text : Agent_core.Types.message =
    { origin = Agent_core.Llm_provider.Types.Conversation
    ; role
    ; content = [ Agent_core.Types.Text text ]
    ; name = None
    ; tool_call_id = None
    ; metadata = []
    }
  in
  check int "declarative max_retained_turns default is 2000" 2000 C.max_retained_turns;
  let keeper_id = "lifecycle-keeper" in
  let commit ?max_retained_turns id prompt reply ts =
    C.commit_turn
      ~keepers_dir
      ~keeper_id
      ~turn_id:(Ids.Turn_id.of_string id)
      ~runtime_kind:C.Agent_core_http
      ~runtime_id:"glm:1"
      ~user_input:prompt
      ~tool_calls_json:(`List [])
      ~assistant_output:reply
      ~usage_json:(`Assoc [])
      ?max_retained_turns
      ~created_at:ts
      ()
    |> require_c
  in
  ignore (commit "lc#1" "prompt 1" "reply 1" 10.0 : C.canonical_turn);
  ignore (commit "lc#2" "prompt 2" "reply 2" 20.0 : C.canonical_turn);
  ignore (commit "lc#3" "prompt 3" "reply 3" 30.0 : C.canonical_turn);
  (* 1. Verify PRAGMA auto_vacuum = INCREMENTAL (2) on newly created store. *)
  let db_file = C.db_path ~keepers_dir ~keeper_id in
  let auto_vacuum_mode =
    let db = Sqlite3.db_open ~mode:`READONLY db_file in
    Fun.protect
      ~finally:(fun () -> ignore (Sqlite3.db_close db : bool))
      (fun () ->
         let stmt = Sqlite3.prepare db "PRAGMA auto_vacuum;" in
         Fun.protect
           ~finally:(fun () -> ignore (Sqlite3.finalize stmt : Sqlite3.Rc.t))
           (fun () ->
              match Sqlite3.step stmt with
              | Sqlite3.Rc.ROW -> Sqlite3.column_int stmt 0
              | _ -> -1))
  in
  check int "canonical turn DB enables PRAGMA auto_vacuum = INCREMENTAL (2)" 2 auto_vacuum_mode;
  (* 2. Compaction watermark prunes seq <= 2 from SQLite while retaining lc#3 and preserving
        parent_turn_id continuity even if all post-reset rows are pruned. *)
  (match
     Keeper_compaction.compact_evicted_messages
       ~keepers_dir
       ~keeper_id
       ~trigger:(Keeper_compaction.Explicit_hard_limit { capacity_bytes = 64_000; observed_bytes = 70_000 })
       ~evicted_messages:
         [ plain_msg User "prompt 1"
         ; plain_msg Assistant "reply 1"
         ; plain_msg User "prompt 2"
         ; plain_msg Assistant "reply 2"
         ]
       ()
   with
   | Ok (Some _) -> ()
   | Ok None -> fail "expected compaction anchor"
   | Error err -> fail (Keeper_compaction.store_error_to_string err));
  let after_compact_rows = C.list_turns ~keepers_dir ~keeper_id |> require_c in
  check (list string) "compaction watermark pruned compacted lc#1 & lc#2 from SQLite"
    [ "lc#3" ]
    (List.map (fun (t : C.canonical_turn) -> Ids.Turn_id.to_string t.turn_id) after_compact_rows);
  (* Compact remaining lc#3 too so canonical_turns becomes empty, then verify lc#4
     still chains parent_turn_id = Some "lc#3"! *)
  (match
     Keeper_compaction.compact_evicted_messages
       ~keepers_dir
       ~keeper_id
       ~trigger:(Keeper_compaction.Explicit_hard_limit { capacity_bytes = 64_000; observed_bytes = 70_000 })
       ~evicted_messages:[ plain_msg User "prompt 3"; plain_msg Assistant "reply 3" ]
       ()
   with
   | Ok (Some _) -> ()
   | Ok None -> fail "expected epoch 2 compaction anchor"
   | Error err -> fail (Keeper_compaction.store_error_to_string err));
  check int "all compacted rows pruned from SQLite" 0
    (List.length (C.list_turns ~keepers_dir ~keeper_id |> require_c));
  let t4 = commit "lc#4" "prompt 4" "reply 4" 40.0 in
  check (option string) "post-compaction commit chains parent across pruned watermark"
    (Some "lc#3")
    (Option.map Ids.Turn_id.to_string t4.parent_turn_id);
  (* 3. record_history_reset prunes pre-reset rows from SQLite and starts fresh parent chain. *)
  C.record_history_reset ~keepers_dir ~keeper_id |> require_c;
  check int "history reset pruned all pre-reset rows from SQLite" 0
    (List.length (C.list_turns ~keepers_dir ~keeper_id |> require_c));
  let t5 = commit "lc#5" "prompt 5" "reply 5" 50.0 in
  check (option string) "first post-reset commit starts fresh parent chain (None)" None
    (Option.map Ids.Turn_id.to_string t5.parent_turn_id);
  (* 4. Retention safety cap prunes oldest rows past max_retained_turns without compaction. *)
  let cap_keeper = "cap-keeper" in
  for i = 1 to 12 do
    ignore
      (C.commit_turn
         ~keepers_dir
         ~keeper_id:cap_keeper
         ~turn_id:(Ids.Turn_id.of_string (Printf.sprintf "cap#%d" i))
         ~runtime_kind:C.Acp_cli
         ~runtime_id:"acp:1"
         ~user_input:(Printf.sprintf "cap prompt %d" i)
         ~tool_calls_json:(`List [])
         ~assistant_output:(Printf.sprintf "cap reply %d" i)
         ~usage_json:(`Assoc [])
         ~max_retained_turns:5
         ~created_at:(float_of_int i)
         ()
       |> require_c)
  done;
  let retained = C.list_turns ~keepers_dir ~keeper_id:cap_keeper |> require_c in
  check (list string) "retention cap keeps strictly the newest 5 turns in seq order"
    [ "cap#8"; "cap#9"; "cap#10"; "cap#11"; "cap#12" ]
    (List.map (fun (t : C.canonical_turn) -> Ids.Turn_id.to_string t.turn_id) retained);
  (* 5. delete_store removes .db plus -wal, -shm, -journal sidecars cleanly and is idempotent. *)
  let cap_db = C.db_path ~keepers_dir ~keeper_id:cap_keeper in
  List.iter
    (fun suffix ->
       let p = cap_db ^ suffix in
       if not (Sys.file_exists p) then ignore (Fs_compat.save_file_atomic p "sidecar"))
    [ "-wal"; "-shm"; "-journal" ];
  check bool "db exists before delete_store" true (Sys.file_exists cap_db);
  C.delete_store ~keepers_dir ~keeper_id:cap_keeper |> require_c;
  List.iter
    (fun suffix ->
       let p = cap_db ^ suffix in
       check bool (Printf.sprintf "delete_store removed %s" suffix) false (Sys.file_exists p))
    [ ""; "-wal"; "-shm"; "-journal" ];
  (* Second call is an idempotent no-op when already absent. *)
  C.delete_store ~keepers_dir ~keeper_id:cap_keeper |> require_c
;;

let test_p0_10_budget_continue_collision_concurrency_redaction_and_zero_byte_db () =
  let plain_msg role text : Agent_core.Types.message =
    { origin = Agent_core.Types.Conversation
    ; role
    ; content = [ Agent_core.Types.Text text ]
    ; name = None
    ; tool_call_id = None
    ; metadata = []
    }
  in
  let tmp = Filename.temp_dir "compaction-p010-" "" in
  let keepers_dir = Filename.concat tmp ".masc/keepers" in
  Fs_compat.mkdir_p keepers_dir;
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree tmp) (fun () ->
    (* 1. provider_limit_tokens = None ALWAYS bounds anchor <= default_anchor_max_bytes *)
    let huge_turns =
      List.init 80 (fun i ->
        let pad = String.make 1024 (Char.chr (65 + (i mod 26))) in
        [ plain_msg User (Printf.sprintf "user goal %d %s" i pad)
        ; plain_msg Assistant (Printf.sprintf "decision %d %s" i pad)
        ])
      |> List.concat
    in
    let anchor_none =
      match
        Keeper_compaction.compact_evicted_messages
          ~keepers_dir
          ~keeper_id:"k-none"
          ~trigger:(Keeper_compaction.Provider_context_overflow { provider_limit_tokens = None })
          ~evicted_messages:huge_turns
          ()
      with
      | Ok (Some a) -> a
      | Ok None -> fail "expected committed anchor for None token limit"
      | Error err -> fail (Keeper_compaction.store_error_to_string err)
    in
    let rendered_none = msg_bytes (Keeper_compaction.anchor_to_message anchor_none) in
    check bool
      (Printf.sprintf "None limit anchor (%d) <= default_anchor_max_bytes (%d)"
         rendered_none Keeper_compaction.default_anchor_max_bytes)
      true
      (rendered_none <= Keeper_compaction.default_anchor_max_bytes);
    check bool "None limit rolled off archived_epochs_through" true
      (Option.is_some anchor_none.archived_epochs_through);

    (* 2. Some 32_000 tokens -> capacity_bytes = 128_000 -> budget = 32_000 bytes (NOT 8_000!) *)
    let medium_turns =
      List.init 15 (fun i ->
        let pad = String.make 900 (Char.chr (97 + (i mod 26))) in
        [ plain_msg User (Printf.sprintf "mid goal %d" i)
        ; plain_msg Assistant (Printf.sprintf "mid decision %d %s" i pad)
        ])
      |> List.concat
    in
    let anchor_tok =
      match
        Keeper_compaction.compact_evicted_messages
          ~keepers_dir
          ~keeper_id:"k-tok"
          ~trigger:(Keeper_compaction.Provider_context_overflow { provider_limit_tokens = Some 32_000 })
          ~evicted_messages:medium_turns
          ()
      with
      | Ok (Some a) -> a
      | Ok None -> fail "expected committed anchor for Some 32_000"
      | Error err -> fail (Keeper_compaction.store_error_to_string err)
    in
    let rendered_tok = msg_bytes (Keeper_compaction.anchor_to_message anchor_tok) in
    check bool
      (Printf.sprintf "Some 32_000 anchor (%d) preserved > 8_000 bytes without 16x over-truncation"
         rendered_tok)
      true
      (rendered_tok > 10_000 && rendered_tok <= 32_000);
    check bool "Some 32_000 did not spuriously roll off under 32 KiB" true
      (Option.is_none anchor_tok.archived_epochs_through);

    (* 3. Identical "Continue." openers with distinct bodies never collide; even identical
          byte-for-byte turns across non-adjacent epochs disambiguate instead of overwriting;
          exact same prefix remains idempotent. *)
    let cont_a = [ plain_msg User "Continue."; plain_msg Assistant "Reply Alpha" ] in
    let cont_b = [ plain_msg User "Continue."; plain_msg Assistant "Reply Beta" ] in
    let a1 =
      match
        Keeper_compaction.compact_evicted_messages
          ~keepers_dir ~keeper_id:"k-cont"
          ~trigger:(Keeper_compaction.Explicit_hard_limit { capacity_bytes = 64_000; observed_bytes = 70_000 })
          ~evicted_messages:cont_a ()
      with
      | Ok (Some a) -> a
      | _ -> fail "epoch 1 Continue. failed"
    in
    let a2 =
      match
        Keeper_compaction.compact_evicted_messages
          ~keepers_dir ~keeper_id:"k-cont"
          ~trigger:(Keeper_compaction.Explicit_hard_limit { capacity_bytes = 64_000; observed_bytes = 70_000 })
          ~evicted_messages:cont_b ()
      with
      | Ok (Some a) -> a
      | _ -> fail "epoch 2 Continue. failed"
    in
    check bool "distinct Continue. turns get distinct covers_through_turn IDs" false
      (String.equal
         (Ids.Turn_id.to_string a1.covers_through_turn)
         (Ids.Turn_id.to_string a2.covers_through_turn));
    (* Now repeat cont_a in epoch 3 (not covered by a2.covers_through_turn): must disambiguate, NOT overwrite a1! *)
    let a3 =
      match
        Keeper_compaction.compact_evicted_messages
          ~keepers_dir ~keeper_id:"k-cont"
          ~trigger:(Keeper_compaction.Explicit_hard_limit { capacity_bytes = 64_000; observed_bytes = 70_000 })
          ~evicted_messages:cont_a ()
      with
      | Ok (Some a) -> a
      | _ -> fail "epoch 3 identical Continue. disambiguation failed"
    in
    check bool "epoch 3 identical Continue. disambiguated from epoch 1" false
      (String.equal
         (Ids.Turn_id.to_string a1.covers_through_turn)
         (Ids.Turn_id.to_string a3.covers_through_turn));
    let ep1_turns =
      Keeper_compaction.load_archived_turns_for_epoch ~keepers_dir ~keeper_id:"k-cont" ~epoch_id:1
      |> Result.get_ok
    in
    let ep2_turns =
      Keeper_compaction.load_archived_turns_for_epoch ~keepers_dir ~keeper_id:"k-cont" ~epoch_id:2
      |> Result.get_ok
    in
    let ep3_turns =
      Keeper_compaction.load_archived_turns_for_epoch ~keepers_dir ~keeper_id:"k-cont" ~epoch_id:3
      |> Result.get_ok
    in
    check int "epoch 1 archived atoms preserved (not overwritten)" 2 (List.length ep1_turns);
    check int "epoch 2 archived atoms preserved (Continue. disambiguated)" 2 (List.length ep2_turns);
    check int "epoch 3 archived atoms preserved separately" 2 (List.length ep3_turns);
    let all_ids =
      List.map (fun (t : Keeper_compaction.canonical_turn) -> Ids.Turn_id.to_string t.turn_id)
        (ep1_turns @ ep2_turns @ ep3_turns)
    in
    check int "all 6 archived atoms across 3 Continue. epochs have distinct turn_ids" 6
      (List.length (List.sort_uniq String.compare all_ids));

    (* 4. Concurrent compact_evicted_messages fibers serialize cleanly inside BEGIN IMMEDIATE *)
    Eio_main.run (fun _env ->
      let errors = ref [] in
      Eio.Fiber.all
        (List.init 6 (fun i () ->
           let msgs =
             [ plain_msg User (Printf.sprintf "concurrent-u-%d" i)
             ; plain_msg Assistant (Printf.sprintf "concurrent-a-%d" i)
             ]
           in
           match
             Keeper_compaction.compact_evicted_messages
               ~keepers_dir ~keeper_id:"k-race"
               ~trigger:(Keeper_compaction.Explicit_hard_limit { capacity_bytes = 64_000; observed_bytes = 70_000 })
               ~evicted_messages:msgs ()
           with
           | Ok (Some _) -> ()
           | Ok None -> errors := "unexpected Ok None" :: !errors
           | Error err -> errors := Keeper_compaction.store_error_to_string err :: !errors));
      check (list string) "zero PRIMARY KEY errors under 6 concurrent compactions" [] !errors);
    let race_epochs =
      Keeper_compaction.list_epochs ~keepers_dir ~keeper_id:"k-race" |> Result.get_ok
    in
    check int "all 6 concurrent epochs committed monotonically" 6 (List.length race_epochs);

    (* 5. Workspace-scoped on_epoch_committed receives exact keepers_dir *)
    let seen_dirs = ref [] in
    Keeper_compaction.set_on_epoch_committed
      (Some (fun ~keepers_dir:kd ~keeper_id anchor ->
         seen_dirs := (kd, keeper_id, anchor.epoch_id) :: !seen_dirs));
    Fun.protect ~finally:(fun () -> Keeper_compaction.set_on_epoch_committed None) (fun () ->
      ignore
        (Keeper_compaction.compact_evicted_messages
           ~keepers_dir ~keeper_id:"k-ws"
           ~trigger:(Keeper_compaction.Provider_context_overflow { provider_limit_tokens = None })
           ~evicted_messages:[ plain_msg User "ws check"; plain_msg Assistant "ws ok" ]
           ()
         |> Result.get_ok));
    check (list (triple string string int)) "callback receives workspace keepers_dir"
      [ keepers_dir, "k-ws", 1 ]
      !seen_dirs;

    (* 6. Secret redaction before .compaction.db persistence and microcompaction *)
    let secret_token = "sk" ^ "-ant-api03-" ^ "COMPACTSECRET9876543210ZYXWVU" in
    let anchor_sec =
      match
        Keeper_compaction.compact_evicted_messages
          ~keepers_dir ~keeper_id:"k-sec"
          ~trigger:(Keeper_compaction.Provider_context_overflow { provider_limit_tokens = None })
          ~evicted_messages:
            [ plain_msg User ("token is " ^ secret_token)
            ; plain_msg Assistant ("confirmed " ^ secret_token)
            ]
          ()
      with
      | Ok (Some a) -> a
      | _ -> fail "expected secret-redacted epoch"
    in
    check bool "secret redacted from committed anchor active_intent" false
      (String_util.contains_substring anchor_sec.active_intent secret_token);
    let archived_sec =
      Keeper_compaction.load_archived_turns_for_epoch ~keepers_dir ~keeper_id:"k-sec" ~epoch_id:1
      |> Result.get_ok
    in
    let archived_text =
      archived_sec
      |> List.concat_map (fun (t : Keeper_compaction.canonical_turn) -> t.messages)
      |> List.map (fun (m : Agent_core.Types.message) ->
        Yojson.Safe.to_string (Agent_core.Checkpoint.message_to_json m))
      |> String.concat "\n"
    in
    check bool "secret redacted from archived_turns messages_json" false
      (String_util.contains_substring archived_text secret_token);
    check bool "[REDACTED] marker persisted in archived_turns" true
      (String_util.contains_substring archived_text "[REDACTED]");

    (* 7. Streaming decode_live_blob_references_json omits raw conversation text &
          0-byte .compaction.db without companions returns Ok None *)
    let decoded_sec =
      Keeper_compaction.decode_live_blob_references_json
        (Keeper_compaction.db_path ~keepers_dir ~keeper_id:"k-sec")
      |> Result.get_ok
    in
    check bool "streaming blob decoder returns None when DB has only plain text (no full AST bloat)" true
      (Option.is_none decoded_sec);
    let zero_path = Keeper_compaction.db_path ~keepers_dir ~keeper_id:"k-zero" in
    Out_channel.with_open_bin zero_path (fun _ -> ());
    check bool "0-byte compaction DB without companions returns Ok None on latest_anchor" true
      (Keeper_compaction.latest_anchor ~keepers_dir ~keeper_id:"k-zero" = Ok None);
    check bool "0-byte compaction DB without companions returns Ok None on blob decoder" true
      (Keeper_compaction.decode_live_blob_references_json zero_path = Ok None))
;;

let test_per_keeper_ssh_redaction_under_config_keepers_and_compact_and_project () =
  with_temp_dir @@ fun base_path ->
  let keepers_dir =
    Filename.concat (Filename.concat (Common.masc_dir_from_base_path ~base_path) "config") "keepers"
  in
  Fs_compat.mkdir_p keepers_dir;
  (* Opaque per-keeper secret (no sk-/ghp_ regex shape) under .masc/ssh/redaction/<keeper>.token *)
  let opaque_secret = "OPAQUE_SSH_KEEPER_TOKEN_99441122" in
  let redaction_dir =
    Filename.concat (Filename.concat (Common.masc_dir_from_base_path ~base_path) "ssh") "redaction"
  in
  Fs_compat.mkdir_p redaction_dir;
  let token_path = Filename.concat redaction_dir "k-proj.token" in
  ignore (Fs_compat.save_file_atomic token_path opaque_secret : (unit, string) result);
  let plain_msg role text : Agent_core.Types.message =
    { origin = Agent_core.Llm_provider.Types.Conversation
    ; role
    ; content = [ Agent_core.Types.Text text ]
    ; name = None
    ; tool_call_id = None
    ; metadata = []
    }
  in
  (* 1. compact_evicted_messages with production <base>/.masc/config/keepers path
        (trailing slash too!) resolves base_path and redacts opaque per-keeper secret. *)
  let anchor_ev =
    match
      Keeper_compaction.compact_evicted_messages
        ~keepers_dir:(keepers_dir ^ "/")
        ~keeper_id:"k-proj"
        ~trigger:(Keeper_compaction.Provider_context_overflow { provider_limit_tokens = None })
        ~evicted_messages:
          [ plain_msg User ("deploy with " ^ opaque_secret)
          ; plain_msg Assistant ("applied " ^ opaque_secret)
          ]
        ()
    with
    | Ok (Some a) -> a
    | _ -> fail "expected epoch under config/keepers"
  in
  check bool "opaque per-keeper secret redacted from anchor active_intent" false
    (contains ~needle:opaque_secret anchor_ev.active_intent);
  check bool "[REDACTED] present in anchor active_intent" true
    (contains ~needle:"[REDACTED]" anchor_ev.active_intent);
  let archived_ev =
    Keeper_compaction.load_archived_turns_for_epoch ~keepers_dir ~keeper_id:"k-proj" ~epoch_id:1
    |> Result.get_ok
  in
  let archived_ev_text =
    archived_ev
    |> List.concat_map (fun (t : Keeper_compaction.canonical_turn) -> t.messages)
    |> List.map (fun m -> Yojson.Safe.to_string (Agent_core.Checkpoint.message_to_json m))
    |> String.concat "\n"
  in
  check bool "opaque per-keeper secret redacted from archived_turns" false
    (contains ~needle:opaque_secret archived_ev_text);

  (* 2. compact_and_project redacts BEFORE bound_anchor_to_budget & enforce_capacity,
        returning redacted messages and evicted_turns (never leaking raw secrets). *)
  let short_opaque = "Z9Q8W7E6" in
  let token_path_2 = Filename.concat redaction_dir "k-proj2.token" in
  ignore (Fs_compat.save_file_atomic token_path_2 short_opaque : (unit, string) result);
  let t1 =
    make_turn ~idx:1
      ~user_text:("rotate secret " ^ short_opaque ^ " " ^ String.make 80 'a')
      ~tool_name:"bash"
      ~tool_output:("output containing " ^ short_opaque)
      ~assistant_text:("rotated " ^ short_opaque)
  in
  let t2 =
    make_turn ~idx:2
      ~user_text:"keep recent turn clean"
      ~tool_name:"read"
      ~tool_output:"ok"
      ~assistant_text:"done"
  in
  let capacity_bytes = 2000 in
  let reserved_bytes = 200 in
  let projected =
    Keeper_compaction.compact_and_project
      ~keepers_dir
      ~keeper_id:"k-proj2"
      ~measure_message_bytes:msg_bytes
      ~capacity_bytes
      ~reserved_bytes
      ~force_trigger:(Keeper_compaction.Provider_context_overflow { provider_limit_tokens = Some 500 })
      [ t1; t2 ]
    |> Result.get_ok
  in
  let all_returned_msg_text =
    projected.messages
    |> List.map (fun m -> Yojson.Safe.to_string (Agent_core.Checkpoint.message_to_json m))
    |> String.concat "\n"
  in
  let all_returned_evicted_text =
    projected.evicted_turns
    |> List.concat_map (fun (t : Keeper_compaction.canonical_turn) -> t.messages)
    |> List.map (fun m -> Yojson.Safe.to_string (Agent_core.Checkpoint.message_to_json m))
    |> String.concat "\n"
  in
  check bool "compact_and_project returned messages do not leak opaque secret" false
    (contains ~needle:short_opaque all_returned_msg_text);
  check bool "compact_and_project returned evicted_turns do not leak opaque secret" false
    (contains ~needle:short_opaque all_returned_evicted_text);
  let total_projected_bytes =
    List.fold_left (fun acc m -> acc + msg_bytes m) 0 projected.messages
  in
  check bool "compact_and_project enforces capacity AFTER redaction expansion" true
    (reserved_bytes + total_projected_bytes <= capacity_bytes);

  (* 3. Duplicate "Continue." turns across epochs in compact_and_project (disambiguate_turns_in_tx
        inside commit_epoch_with_handles_full) never raise SQLITE_CONSTRAINT_PRIMARYKEY. *)
  let dup_turn =
    { Keeper_compaction.turn_id = Ids.Turn_id.of_string "turn-continue-dup"
    ; messages = [ plain_msg User "Continue."; plain_msg Assistant "Continuing task." ]
    }
  in
  let keep_turn_1 =
    make_turn ~idx:10 ~user_text:"keep-1" ~tool_name:"read" ~tool_output:"ok" ~assistant_text:"a1"
  in
  let keep_turn_2 =
    make_turn ~idx:11 ~user_text:"keep-2" ~tool_name:"read" ~tool_output:"ok" ~assistant_text:"a2"
  in
  let proj_ep1 =
    Keeper_compaction.compact_and_project
      ~keepers_dir
      ~keeper_id:"k-dup-proj"
      ~measure_message_bytes:msg_bytes
      ~capacity_bytes:2000
      ~reserved_bytes:200
      ~force_trigger:(Keeper_compaction.Provider_context_overflow { provider_limit_tokens = Some 500 })
      [ dup_turn; keep_turn_1 ]
    |> Result.get_ok
  in
  let anchor_ep1 = Option.get proj_ep1.anchor in
  let proj_ep2 =
    Keeper_compaction.compact_and_project
      ~keepers_dir
      ~keeper_id:"k-dup-proj"
      ~measure_message_bytes:msg_bytes
      ~capacity_bytes:2000
      ~reserved_bytes:200
      ~force_trigger:(Keeper_compaction.Provider_context_overflow { provider_limit_tokens = Some 500 })
      [ dup_turn; keep_turn_2 ]
    |> Result.get_ok
  in
  let anchor_ep2 = Option.get proj_ep2.anchor in
  check int "second compact_and_project epoch committed monotonically" 2 anchor_ep2.epoch_id;
  check bool "duplicate turn_id disambiguated in epoch 2 covers_through_turn" false
    (String.equal
       (Ids.Turn_id.to_string anchor_ep1.covers_through_turn)
       (Ids.Turn_id.to_string anchor_ep2.covers_through_turn));
  let ep1_archived =
    Keeper_compaction.load_archived_turns_for_epoch ~keepers_dir ~keeper_id:"k-dup-proj" ~epoch_id:1
    |> Result.get_ok
  in
  let ep2_archived =
    Keeper_compaction.load_archived_turns_for_epoch ~keepers_dir ~keeper_id:"k-dup-proj" ~epoch_id:2
    |> Result.get_ok
  in
  check int "epoch 1 duplicate turn preserved" 1 (List.length ep1_archived);
  check int "epoch 2 duplicate turn preserved separately" 1 (List.length ep2_archived);
  check string "epoch 2 covers_through_turn matches disambiguated archived turn_id"
    (Ids.Turn_id.to_string (List.hd ep2_archived).turn_id)
    (Ids.Turn_id.to_string anchor_ep2.covers_through_turn)
;;

let test_p1_5_live_history_after_latest_anchor_scopes_tool_carry () =
  with_temp_dir @@ fun base_path ->
  let keepers_dir =
    Filename.concat (Filename.concat (Common.masc_dir_from_base_path ~base_path) "config") "keepers"
  in
  Fs_compat.mkdir_p keepers_dir;
  let turn_atom ~prompt ~tool_name ~answer : Agent_core.Types.message list =
    let call_id = "call-" ^ tool_name in
    [ { origin = Agent_core.Llm_provider.Types.Conversation
      ; role = Agent_core.Types.User
      ; content = [ Agent_core.Types.Text prompt ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    ; { origin = Agent_core.Llm_provider.Types.Conversation
      ; role = Agent_core.Types.Assistant
      ; content = [ Agent_core.Types.ToolUse { id = call_id; name = tool_name; input = `Assoc [] } ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    ; { origin = Agent_core.Llm_provider.Types.Conversation
      ; role = Agent_core.Types.Tool
      ; content =
          [ Agent_core.Types.ToolResult
              { tool_use_id = call_id
              ; content = "ok"
              ; outcome = Agent_core.Types.Tool_succeeded
              ; json = None
              ; content_blocks = None
              }
          ]
      ; name = None
      ; tool_call_id = Some call_id
      ; metadata = []
      }
    ; { origin = Agent_core.Llm_provider.Types.Conversation
      ; role = Agent_core.Types.Assistant
      ; content = [ Agent_core.Types.Text answer ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    ]
  in
  let atom0 = turn_atom ~prompt:"epoch1 turn 0" ~tool_name:"svc_old_a" ~answer:"done a" in
  let atom1 = turn_atom ~prompt:"epoch1 turn 1" ~tool_name:"svc_old_b" ~answer:"done b" in
  let atom2 = turn_atom ~prompt:"epoch2 turn 2" ~tool_name:"svc_live_c" ~answer:"done c" in
  let full_history = atom0 @ atom1 @ atom2 in
  (* Before any compaction anchor exists, full history is returned unchanged. *)
  check int "without anchor, full durable history is preserved"
    (List.length full_history)
    (List.length
       (Keeper_compaction.live_history_after_latest_anchor
          ~keepers_dir ~keeper_id:"k-tool-carry" full_history));
  (* Commit compaction covering atoms 0 and 1. *)
  let anchor =
    match
      Keeper_compaction.compact_evicted_messages
        ~keepers_dir
        ~keeper_id:"k-tool-carry"
        ~trigger:(Keeper_compaction.Provider_context_overflow { provider_limit_tokens = Some 4096 })
        ~evicted_messages:(atom0 @ atom1)
        ()
    with
    | Ok (Some a) -> a
    | Ok None -> fail "expected committed compaction anchor"
    | Error err -> fail (Keeper_compaction.store_error_to_string err)
  in
  let live_tail =
    Keeper_compaction.live_history_after_latest_anchor
      ~keepers_dir ~keeper_id:"k-tool-carry" full_history
  in
  let tool_names_in msgs =
    msgs
    |> List.concat_map (fun (m : Agent_core.Types.message) ->
      List.filter_map
        (function
          | Agent_core.Types.ToolUse { name; _ } -> Some name
          | Text _ | Thinking _ | RedactedThinking _ | ToolResult _
          | ToolReference _ | Image _ | Document _ | Audio _ | ReasoningDetails _ -> None)
        m.content)
  in
  check (list string) "persisted anchor drops pre-compaction ToolUse atoms and keeps live tail"
    [ "svc_live_c" ]
    (tool_names_in live_tail);
  (* Disambiguated covers_through_turn suffix (-ep2-0) also matches atom 1 cleanly. *)
  let disambiguated_anchor =
    { anchor with
      covers_through_turn =
        Ids.Turn_id.of_string (Ids.Turn_id.to_string anchor.covers_through_turn ^ "-ep2-0")
    }
  in
  check (list string) "disambiguated covers_through_turn matches and slices live tail"
    [ "svc_live_c" ]
    (tool_names_in (Keeper_compaction.messages_after_anchor ~anchor:disambiguated_anchor full_history));
  (* Non-prefix re-indexed eviction (e.g., atom 1 compacted alone as atom-0-<hash>)
     still matches atom 1 by content hash and slices strictly to atom 2. *)
  let reindexed_anchor =
    match
      Keeper_compaction.compact_evicted_messages
        ~keepers_dir
        ~keeper_id:"k-tool-carry-reindexed"
        ~trigger:(Keeper_compaction.Provider_context_overflow { provider_limit_tokens = Some 4096 })
        ~evicted_messages:atom1
        ()
    with
    | Ok (Some a) -> a
    | Ok None -> fail "expected reindexed compaction anchor"
    | Error err -> fail (Keeper_compaction.store_error_to_string err)
  in
  check (list string) "reindexed evicted atom still slices strictly after atom 1"
    [ "svc_live_c" ]
    (tool_names_in (Keeper_compaction.messages_after_anchor ~anchor:reindexed_anchor full_history));
  (* When a later live-epoch turn repeats the exact same atom content hash as
     a compacted re-indexed atom (e.g. repeated autonomous "Continue." turns),
     messages_after_anchor must anchor at the earliest valid atom so live-epoch
     carried tools are never dropped mid-epoch (zero prompt-cache bust). *)
  let repeated_history = atom0 @ atom1 @ atom2 @ atom1 in
  check (list string)
    "reindexed anchor matches earliest valid atom and keeps live-epoch tools despite repeated later turn"
    [ "svc_live_c"; "svc_old_b" ]
    (tool_names_in
       (Keeper_compaction.messages_after_anchor ~anchor:reindexed_anchor repeated_history));
  (* When messages carry an older inline compaction anchor (e.g. epoch 1 after
     atom0) while the persisted DB anchor has advanced to epoch 2 (covering
     atom1), slice strictly past max(inline_pos, db_anchor_pos) so epoch-2
     compacted messages do not leak back into tool carry. *)
  let older_inline_anchor : Agent_core.Types.message =
    { origin = Agent_core.Llm_provider.Types.Outside_context
    ; role = Agent_core.Types.User
    ; content = [ Agent_core.Types.Text "epoch-1 handoff" ]
    ; name = None
    ; tool_call_id = None
    ; metadata = Runtime_model_input_tail_window.compaction_anchor_metadata
    }
  in
  let history_with_stale_inline = atom0 @ [ older_inline_anchor ] @ atom1 @ atom2 in
  check (list string)
    "newer DB covers_through_turn advances past an older inline compaction anchor"
    [ "svc_live_c" ]
    (tool_names_in
       (Keeper_compaction.messages_after_anchor ~anchor history_with_stale_inline));
  (* Unmatched covers_through_turn fails open to full history so live turns are never dropped. *)
  let unrelated_anchor =
    { anchor with covers_through_turn = Ids.Turn_id.of_string "turn-not-in-history" }
  in
  check (list string) "unmatched anchor fails open to full history"
    [ "svc_old_a"; "svc_old_b"; "svc_live_c" ]
    (tool_names_in (Keeper_compaction.messages_after_anchor ~anchor:unrelated_anchor full_history))
;;

let () =
  run
    "keeper_compaction"
    [ ( "blob_store_and_handles"
      , [ test_case "structured handle & 4 KiB head+tail preview & non-Scanf marker" `Quick
            test_tool_output_structured_handle_and_head_tail_preview
        ] )
    ; ( "anchored_compaction"
      , [ test_case "typed tool evidence, pre-change epochs and inline replay" `Quick
            test_transcript_evidence_survives_restart
        ; test_case "P0-10 & P1-9 budget, Continue. collision, concurrency, workspace hook, redaction & 0-byte DB" `Quick
            test_p0_10_budget_continue_collision_concurrency_redaction_and_zero_byte_db
        ; test_case "per-keeper SSH redaction under config/keepers & compact_and_project pre-budget redaction" `Quick
            test_per_keeper_ssh_redaction_under_config_keepers_and_compact_and_project
        ; test_case "microcompaction, incremental epochs, lossless Turn_id pointers & WAL isolation" `Quick
            test_microcompaction_and_anchored_iterative_epochs
        ; test_case "Capacity_exceeded, compact_evicted_messages & live try_provider anchor wiring" `Quick
            test_capacity_exceeded_and_live_try_provider_wiring
        ; test_case "60-epoch bounded lossless anchor roll-off & provider down-switch" `Quick
            test_multi_epoch_bounded_anchor_rolloff_and_lossless_recall
        ; test_case "microcompaction put_durable handles protected by Tool_blob_maintenance sweep" `Quick
            test_microcompaction_durable_blobs_protected_from_sweep
        ; test_case "canonical turn store compaction watermark, cycle guard & failover hydration" `Quick
            test_canonical_turn_store_compaction_watermark_and_failover
        ; test_case "canonical turn hydration: suppressed terminal effect, multi-block & repeated prompts" `Quick
            test_canonical_turn_hydration_edge_cases
        ; test_case "canonical turn multi-epoch watermark monotonicity & unmapped epoch floor" `Quick
            test_canonical_turn_multi_epoch_watermark_monotonicity
        ; test_case "canonical turn disk lifecycle: auto_vacuum, prune, retention cap & delete_store" `Quick
            test_canonical_turn_disk_lifecycle_prune_and_delete
        ; test_case "P1-5 live_history_after_latest_anchor scopes non-Anthropic tool carry across compaction" `Quick
            test_p1_5_live_history_after_latest_anchor_scopes_tool_carry
        ] )
    ]
;;
