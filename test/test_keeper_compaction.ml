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
  check bool "verified facts carry lossless Turn_id pointers" true
    (anchor1.verified_facts_and_files <> []);
  check bool "first projected message is pinned compaction anchor" true
    (match ctx_epoch1.messages with
     | first :: _ -> Runtime_model_input_tail_window.is_compaction_anchor first
     | [] -> false);
  (* 4. Lossless archived turn retrieval by Turn_id.t from per-Keeper SQLite WAL
        MUST preserve raw pre-microcompaction verbatim bodies even after all
        externalized Tool_blob_store files are swept/deleted! *)
  let tool_blobs_dir = Filename.concat (Filename.concat base_path ".masc") "tool_blobs" in
  if Sys.file_exists tool_blobs_dir then Fs_compat.remove_tree tool_blobs_dir;
  let _, first_ptr = List.hd anchor1.verified_facts_and_files in
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
    (List.for_all (fun entry -> List.mem entry anchor2.verified_facts_and_files) anchor1.verified_facts_and_files);
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
    (Some (fun ~keeper_id anchor -> hook_epochs := (keeper_id, anchor.epoch_id) :: !hook_epochs));
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

let () =
  run
    "keeper_compaction"
    [ ( "blob_store_and_handles"
      , [ test_case "structured handle & 4 KiB head+tail preview & non-Scanf marker" `Quick
            test_tool_output_structured_handle_and_head_tail_preview
        ] )
    ; ( "anchored_compaction"
      , [ test_case "microcompaction, incremental epochs, lossless Turn_id pointers & WAL isolation" `Quick
            test_microcompaction_and_anchored_iterative_epochs
        ; test_case "Capacity_exceeded, compact_evicted_messages & live try_provider anchor wiring" `Quick
            test_capacity_exceeded_and_live_try_provider_wiring
        ; test_case "60-epoch bounded lossless anchor roll-off & provider down-switch" `Quick
            test_multi_epoch_bounded_anchor_rolloff_and_lossless_recall
        ; test_case "microcompaction put_durable handles protected by Tool_blob_maintenance sweep" `Quick
            test_microcompaction_durable_blobs_protected_from_sweep
        ] )
    ]
;;
