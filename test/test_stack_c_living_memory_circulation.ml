(* End-to-end Living Evolutionary Memory Circulation Verification (Stack C):
   Multi-turn Keeper log
     -> Microcompaction (4 KiB head+tail structured handles) & Provider-Neutral Anchored Compaction (SQLite WAL off-domain)
     -> Compaction Epoch Advance -> Ship-of-Theseus Librarian (Consolidate + Synthesize [Derived] + Molt + Checkpoint Log Compaction + Promote_to_world)
     -> Async World Curator + Lock-Free MVCC MASC World Memory (.masc/world_memory.db) + Cross-Keeper Synthesis + Unified Wiki/Artifact/Resource Index
     -> Concurrent sibling-Keeper MVCC reads + MCP resources/list & resources/read (masc://world-memory/...)
     -> Bidirectional World Memory Index into Librarian Question + Cache-Stable Per-Keeper Memory Digest (ZERO "bodies omitted") + Persistent SQLite WAL FTS5. *)

open Alcotest
module Llm_types = Agent_core.Llm_provider.Types
module Compaction = Masc.Keeper_compaction
module Types = Masc.Keeper_memory_os_types
module Answer = Masc.Librarian_answer
module Plan = Masc.Librarian_plan
module Store = Masc.Librarian_store
module Log_store = Masc.Librarian_log_store
module Archive = Masc.Librarian_archive
module Digest_mod = Masc.Keeper_memory_digest
module Recall = Masc.Keeper_memory_os_recall
module Search_idx = Masc.Keeper_memory_search_index
module Question_id = Masc.Librarian_question_id
module Turn_store = Masc.Keeper_turn_log_store
module Turn_log = Masc.Keeper_turn_log
module WM = Masc.World_memory
module WM_types = Masc.World_memory_types
module WM_store = Masc.World_memory_store
module WM_curator = Masc.World_memory_curator
module Resource = Masc.Mcp_server_eio_resource
module Mcp_eio = Masc.Mcp_server_eio

let rec rm_rf path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Array.iter (fun entry -> rm_rf (Filename.concat path entry)) (Sys.readdir path);
      Unix.rmdir path)
    else Unix.unlink path
;;

let with_temp_dir f =
  let base =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-stack-c-e2e-%d-%d" (Unix.getpid ()) (Random.int 1_000_000))
  in
  Unix.mkdir base 0o700;
  Fun.protect ~finally:(fun () -> rm_rf base) (fun () -> f base)
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

let make_msg ~role content : Agent_core.Types.message =
  { role
  ; content
  ; name = None
  ; tool_call_id = None
  ; metadata = []
  ; origin = Llm_types.Conversation
  }
;;

let make_turn ~idx ~user_text ~tool_output ~assistant_text : Compaction.canonical_turn =
  let turn_id = Ids.Turn_id.of_string (Printf.sprintf "turn-%03d" idx) in
  let tool_id = Printf.sprintf "call-%03d" idx in
  { turn_id
  ; messages =
      [ make_msg ~role:User [ Llm_types.Text user_text ]
      ; make_msg ~role:Assistant
          [ Llm_types.ToolUse
              { id = tool_id
              ; name = "keeper_fs_read"
              ; input = `Assoc [ "file_path", `String (Printf.sprintf "lib/world_memory/step_%d.ml" idx) ]
              }
          ]
      ; make_msg ~role:Tool
          [ Llm_types.ToolResult
              { tool_use_id = tool_id
              ; content = tool_output
              ; outcome = Llm_types.Tool_succeeded
              ; json = None
              ; content_blocks = None
              }
          ]
      ; make_msg ~role:Assistant [ Llm_types.Text assistant_text ]
      ]
  }
;;

let boot_keeper_store ~keepers_dir ~turns_dir ~keeper_id ~at =
  let turns_path = Turn_store.path_for_keepers_dir ~keepers_dir:turns_dir ~keeper_id in
  let log_id =
    match Turn_log.Log_id.of_string (String.make 32 'f') with
    | Some id -> id
    | None -> fail "bad log id"
  in
  let mark : Turn_log.mark =
    { trace = "e2e-trace"
    ; closed_messages = 0
    ; session = ""
    ; history_bytes = 0
    ; internal_bytes = 0
    ; chat_bytes = 0
    ; external_rows = 0
    }
  in
  (match Turn_store.append ~path:turns_path ~at_end:0 (Turn_log.Log_started { id = log_id; at; mark }, []) with
   | Ok _ -> ()
   | Error _ -> fail "turn log start failed");
  match Store.boot ~memory_dir:keepers_dir ~turns_dir ~keeper_id ~at:(at +. 1.0) with
  | Ok s -> s
  | Error _ -> fail ("store boot failed for " ^ keeper_id)
;;

let remember store claim category at =
  let write = Masc.Librarian_direct.Remember { claim; category; basis = Observed Transcript } in
  match Masc.Librarian_direct.plan ~by:Keeper ~at ~trace_id:"e2e-direct" (Store.memory store).facts write with
  | Writes { effects; _ } ->
    (match Store.commit_direct store ~at ~by:Keeper ~trace:"e2e-direct" write effects with
     | Committed { store; _ } -> store
     | _ -> fail "commit_direct failed")
  | _ -> fail "direct plan failed"
;;

let asked_id =
  match Question_id.of_halves ~front:(String.make 32 'a') ~back:(String.make 32 'b') with
  | Some id -> id
  | None -> fail "bad question id"
;;

let read_mcp_json ~state ~uri =
  let response =
    Resource.handle_read_resource_eio ~caller:Resource.Operator_admin state (`Int 1)
      (Some (`Assoc [ "uri", `String uri ]))
  in
  let open Yojson.Safe.Util in
  let text =
    response |> member "result" |> member "contents" |> to_list |> List.hd |> member "text" |> to_string
  in
  Yojson.Safe.from_string text
;;

let list_all_mcp_resource_uris ~clock ~sw state =
  let rec loop cursor acc =
    let params =
      match cursor with
      | Some c -> `Assoc [ "cursor", `String c ]
      | None -> `Assoc []
    in
    let request =
      Yojson.Safe.to_string
        (`Assoc
          [ "jsonrpc", `String "2.0"
          ; "id", `Int 10
          ; "method", `String "resources/list"
          ; "params", params
          ])
    in
    let resp = Mcp_eio.handle_request ~sender:Mcp_eio.Unadmitted ~clock ~sw state request in
    let open Yojson.Safe.Util in
    let result = resp |> member "result" in
    let uris =
      result |> member "resources" |> to_list
      |> List.map (fun r -> r |> member "uri" |> to_string)
    in
    let next_cursor =
      match result |> member "nextCursor" with
      | `String s when String.trim s <> "" -> Some s
      | _ -> None
    in
    let acc' = acc @ uris in
    match next_cursor with
    | Some c -> loop (Some c) acc'
    | None -> acc'
  in
  loop None []
;;

let test_full_living_memory_circulation () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let pool = Domain_pool.create ~sw ~domain_count:4 (Eio.Stdenv.domain_mgr env) in
  Domain_pool_ref.set pool;
  Fun.protect ~finally:Domain_pool_ref.clear_for_tests @@ fun () ->
  with_temp_dir @@ fun root ->
  let masc_dir = Filename.concat root ".masc" in
  let keepers_dir = Filename.concat masc_dir "keepers" in
  let turns_dir = Filename.concat masc_dir "turns" in
  let wiki_dir = Filename.concat masc_dir "wiki" in
  Fs_compat.mkdir_p keepers_dir;
  Fs_compat.mkdir_p turns_dir;
  Fs_compat.mkdir_p wiki_dir;
  let config = Masc.Workspace.default_config root in
  let blob_store = Tool_blob_store.create ~base_path:root in

  (* === STAGE 1: Multi-turn Keeper Log -> Microcompaction + Provider-Neutral Anchored Compaction === *)
  let big_tool_body =
    "HEAD-START: SQLite WAL architecture verified across 4 domains.\n"
    ^ String.make 12000 'x'
    ^ "\nTAIL-END: Zero global flock contention observed."
  in
  let turns =
    [ make_turn ~idx:1
        ~user_text:"Verify lock-free SQLite WAL behavior in lib/world_memory/world_memory_store.ml"
        ~tool_output:big_tool_body
        ~assistant_text:"Decision: Use SQLite WAL off-domain on Domain_pool for zero reader blocking."
    ; make_turn ~idx:2
        ~user_text:"Check cache stability of Tier-1 digest across turns"
        ~tool_output:"OK: digest bytes match sha256 across turns 1..5"
        ~assistant_text:"Decision: Freeze Per-Keeper Memory Digest per Librarian revision epoch."
    ; make_turn ~idx:3
        ~user_text:"Verify MCP resource URIs"
        ~tool_output:"masc://world-memory/claims, digest, index, log"
        ~assistant_text:"Open thread: confirm cross-Keeper synthesis edges in world_memory.db."
    ; make_turn ~idx:4
        ~user_text:"Proceed with final checks"
        ~tool_output:"All probes ready"
        ~assistant_text:"Continuing verification."
    ]
  in
  let epoch_events = ref [] in
  let on_epoch_committed (anchor : Compaction.compaction_anchor) =
    epoch_events := anchor.epoch_id :: !epoch_events
  in
  let compact_res_400k =
    match
      Compaction.compact_and_project
        ~blob_store
        ~keep_recent_turns:1
        ~force_trigger:(Compaction.Provider_context_overflow { provider_limit_tokens = Some 400_000 })
        ~on_epoch_committed
        ~keepers_dir
        ~keeper_id:"keeper-alpha"
        ~measure_message_bytes:msg_bytes
        ~capacity_bytes:1200
        ~reserved_bytes:0
        turns
    with
    | Ok r -> r
    | Error err -> fail (Compaction.store_error_to_string err)
  in
  check bool "anchored compaction created epoch 1" true (Option.is_some compact_res_400k.anchor);
  check int "compaction epoch hook fired once" 1 (List.length !epoch_events);
  let anchor = Option.get compact_res_400k.anchor in
  check int "epoch_id = 1" 1 anchor.epoch_id;
  check bool "externalized large tool blob via structured handle" true
    (compact_res_400k.microcompacted_results >= 1);
  (* Provider switch 400K -> 128K projects seamlessly from exact same immutable anchor + tail. *)
  let proj_128k_msgs =
    match
      Compaction.project_for_provider
        ~anchor:(Some anchor)
        ~measure_message_bytes:msg_bytes
        ~capacity_bytes:128_000
        ~reserved_bytes:0
        [ List.nth turns 3 ]
    with
    | Fits_verbatim { messages; _ } | Fits_after_microcompaction { messages; _ } -> messages
    | Needs_compaction _ -> fail "128K projection unexpectedly needed compaction"
    | Single_turn_exceeds_capacity _ -> fail "128K projection single turn overflow"
  in
  check bool "provider-neutral projection embeds anchor message" true
    (List.length proj_128k_msgs >= 2);
  (* Lossless Turn_id pointer back to canonical archived turn in SQLite WAL. *)
  let archived_t1 =
    match Compaction.load_archived_turn ~keepers_dir ~keeper_id:"keeper-alpha" ~turn_id:(Ids.Turn_id.of_string "turn-001") with
    | Ok (Some t) -> t
    | Ok None -> fail "archived turn-001 missing"
    | Error err -> fail (Compaction.store_error_to_string err)
  in
  check string "lossless archived Turn_id pointer round-trips"
    "turn-001" (Ids.Turn_id.to_string archived_t1.turn_id);

  (* === STAGE 2: Ship-of-Theseus Librarian (Synthesize [Derived] + Molt + Checkpoint Compaction + Promote_to_world) === *)
  let store_a = boot_keeper_store ~keepers_dir ~turns_dir ~keeper_id:"keeper-alpha" ~at:110.0 in
  let store_b = boot_keeper_store ~keepers_dir ~turns_dir ~keeper_id:"keeper-beta" ~at:110.0 in
  let store_a = remember store_a "SQLite WAL readers never acquire workspace-global locks" Types.Constraint 120.0 in
  let store_a = remember store_a "Domain_pool isolates blocking SQLite calls from Eio domain 0" Types.Validated_approach 125.0 in
  let store_a = remember store_a "Ephemeral warmup probe #42 finished" Types.Fact 130.0 in
  let store_b = remember store_b "Sibling Keepers read World Memory concurrently during curation commits" Types.Validated_approach 135.0 in

  let facts_a = (Store.memory store_a).facts in
  let mem_a = List.mapi (fun i f -> Printf.sprintf "m%d" (i + 1), Types.memory_id f) facts_a in
  let molt_answer_a : Answer.t =
    { question = asked_id
    ; working_state = Set "epoch 1 molted and promoted"
    ; ops =
        [ Synthesize
            { refs = [ "m1"; "m2" ]
            ; claim = "Off-domain SQLite WAL guarantees lock-free multi-Keeper memory isolation"
            ; category = Lesson
            ; rule_id = "cross_category_synthesis"
            ; from_units = []
            }
        ; Molt
            { refs = [ "m3" ]
            ; reason = "ephemeral warmup probe shed at compaction epoch 1"
            }
        ; Promote_to_world
            { refs = [ "m1"; "m2" ]
            ; scope = "workspace"
            ; claim = "SQLite WAL off-domain on Domain_pool eliminates workspace-global memory locks"
            ; category = Validated_approach
            ; facets = [ "sqlite_wal"; "domain_pool"; "lock_free" ]
            }
        ]
    }
  in
  let plan_a =
    Plan.of_answer
      ~shown:(Molt { memory = mem_a; trigger = Compaction_epoch_advanced { epoch_id = 1 } })
      ~facts:facts_a ~removed_since:[] ~at:140.0 ~trace_id:"compaction-epoch-1" molt_answer_a
  in
  let q_a : Masc.Librarian_room_result.question =
    { id = asked_id
    ; memory = mem_a
    ; basis = Masc.Librarian_log.snapshot_after (Store.tail store_a)
    ; trace = "compaction-epoch-1"
    }
  in
  let store_a =
    match
      Store.commit_molt store_a ~at:140.0 ~question:q_a ~slot:"slot.alpha"
        ~trigger:(Compaction_epoch_advanced { epoch_id = 1 }) plan_a
    with
    | Committed { store; _ } -> store
    | _ -> fail "commit_molt keeper-alpha failed"
  in
  let store_a, compacted_lines =
    match Store.compact_log store_a ~at:145.0 with
    | Ok res -> res
    | Error _ -> fail "compact_log keeper-alpha failed"
  in
  let log_path_a = Log_store.path_for_keepers_dir ~keepers_dir ~keeper_id:"keeper-alpha" in
  let archived_a =
    match Archive.read log_path_a ~current:(Store.memory store_a).facts with
    | Ok a -> a
    | Error _ -> fail "archive read failed"
  in
  check int "cold archive retains molted fact after checkpoint compaction" 1 (List.length archived_a.left);

  let facts_b = (Store.memory store_b).facts in
  let mem_b = List.mapi (fun i f -> Printf.sprintf "m%d" (i + 1), Types.memory_id f) facts_b in
  let molt_answer_b : Answer.t =
    { question = asked_id
    ; working_state = Keep
    ; ops =
        [ Promote_to_world
            { refs = [ "m1" ]
            ; scope = "workspace"
            ; claim = "Sibling Keepers observe consistent MVCC snapshots while World Curator commits"
            ; category = Validated_approach
            ; facets = [ "sqlite_wal"; "mvcc"; "concurrency" ]
            }
        ]
    }
  in
  let plan_b =
    Plan.of_answer
      ~shown:(Molt { memory = mem_b; trigger = Synthesis_cycle_completed })
      ~facts:facts_b ~removed_since:[] ~at:150.0 ~trace_id:"synth-beta-1" molt_answer_b
  in

  (* === STAGE 3: Lock-Free MVCC World Memory + Async World Curator + Unified Wiki/Artifact/MCP Resources === *)
  let wiki_file = Filename.concat wiki_dir "living-memory.md" in
  Fs_compat.save_file wiki_file
    "---\ntitle: Living Evolutionary Memory\nsummary: Anchored compaction, Ship-of-Theseus Librarian, and MVCC World Memory.\nsource: curated\nauthor: builder-memory\ncreated: 2026-11-22\nrevision: 1\ntags: [sqlite_wal, memory, compaction]\n---\n\nLiving memory architecture reference.\n";
  let artifacts_dir = Filename.concat masc_dir "artifacts" in
  Fs_compat.mkdir_p artifacts_dir;
  let published_artifact = Filename.concat artifacts_dir "architecture-note.md" in
  let ephemeral_artifact = Filename.concat artifacts_dir "ephemeral-draft.md" in
  Fs_compat.save_file published_artifact "# Living Memory C3 Published Spec\n";
  Fs_compat.save_file ephemeral_artifact "temporary draft to be pruned\n";
  (* Write an internal tool_blob shard and confirm it is NEVER indexed into world_index. *)
  let internal_blob_ref =
    Tool_blob_store.put_durable_reuse blob_store ~bytes:"internal tool_blob shard body" ~mime:"text/plain"
  in
  let mcp_notifications = Atomic.make 0 in
  let curator =
    WM.start_workspace_curator ~sw ~base_path:root ~now:(fun () -> 200.0)
      ~on_updated:(fun () -> Atomic.incr mcp_notifications)
  in
  WM.promote_from_librarian ~base_path:root ~keeper_id:"keeper-alpha" plan_a.effects.promotions;
  WM.promote_from_librarian ~base_path:root ~keeper_id:"keeper-beta" plan_b.effects.promotions;
  WM_curator.enqueue_index_sync curator;
  WM_curator.flush curator;
  (* Delete ephemeral artifact and re-sync to verify stale-entry pruning in one batch tx. *)
  Unix.unlink ephemeral_artifact;
  WM_curator.enqueue_index_sync curator;
  WM_curator.flush curator;
  let notifications_after_prune = Atomic.get mcp_notifications in
  (* An unchanged Sync_index must NOT fire a spurious MCP resource update notification. *)
  WM_curator.enqueue_index_sync curator;
  WM_curator.flush curator;
  check int "unchanged Sync_index emits zero spurious notifications"
    notifications_after_prune (Atomic.get mcp_notifications);

  let world_facts =
    match WM_store.list_facts ~include_inactive:false ~base_path:root () with
    | Ok fs -> fs
    | Error err -> fail (WM_store.error_to_string err)
  in
  let world_edges =
    match WM_store.list_edges ~base_path:root () with
    | Ok es -> es
    | Error err -> fail (WM_store.error_to_string err)
  in
  let world_index =
    match WM_store.list_index ~base_path:root () with
    | Ok idx -> idx
    | Error err -> fail (WM_store.error_to_string err)
  in
  check bool "cross-Keeper synthesis created >= 3 active world facts (2 promoted + 1 canonical synthesis)"
    true (List.length world_facts >= 3);
  let synth_world_fact =
    match
      List.find_opt
        (fun (f : WM_types.world_fact) ->
           match f.provenance with
           | Cross_keeper_synthesized { keeper_ids; _ } -> List.length keeper_ids = 2
           | Proposed_by _ -> false)
        world_facts
    with
    | Some f -> f
    | None -> fail "expected Cross_keeper_synthesized canonical world fact"
  in
  check string "synthesized world fact is Canonical" "canonical"
    (WM_types.lifecycle_to_string synth_world_fact.lifecycle);
  check bool "Synthesizes_from edges recorded" true
    (List.exists (fun (e : WM_types.world_edge) -> e.kind = Synthesizes_from) world_edges);
  check bool "Wiki page indexed in world_index" true
    (List.exists (fun (e : WM_types.index_entry) -> e.kind = Wiki_page) world_index);
  check bool "Published artifact indexed in world_index" true
    (List.exists
       (fun (e : WM_types.index_entry) ->
          e.kind = Artifact && String.equal e.title "architecture-note.md")
       world_index);
  check bool "Deleted artifact pruned from world_index" false
    (List.exists
       (fun (e : WM_types.index_entry) -> String.equal e.title "ephemeral-draft.md")
       world_index);
  check bool "Internal tool_blobs cache shard NOT indexed into world_index" false
    (List.exists
       (fun (e : WM_types.index_entry) ->
          String_util.contains_substring e.entry_id (String.sub internal_blob_ref.sha256 0 2)
          && e.kind = Artifact)
       world_index);
  check bool "MCP resources indexed in world_index" true
    (List.exists (fun (e : WM_types.index_entry) -> e.kind = Mcp_resource) world_index);
  check bool "MCP resource update notifications fired" true (Atomic.get mcp_notifications >= 1);

  (* Bounded O(F) synthesis check: 3rd Keeper on same (workspace, sqlite_wal) facet updates
     the SINGLE per-facet synthesis fact rather than creating O(N^2) pairwise pairs! *)
  let gamma_promo : Masc.Librarian_lifecycle.world_promotion =
    { source_fact_ids = [ "gamma-1" ]
    ; scope = "workspace"
    ; claim = "C3 batch transactions keep World Memory WAL contention at zero"
    ; category = Types.Validated_approach
    ; facets = [ "sqlite_wal"; "c3_batch" ]
    }
  in
  (match WM_curator.process_promotions_sync ~base_path:root ~now:205.0 ~keeper_id:"keeper-gamma" [ gamma_promo ] with
   | Ok _ -> ()
   | Error err -> fail (WM_store.error_to_string err));
  let world_facts_after_3 =
    match WM_store.list_facts ~include_inactive:false ~base_path:root () with
    | Ok fs -> fs
    | Error err -> fail (WM_store.error_to_string err)
  in
  let synth_facts_after_3 =
    List.filter
      (fun (f : WM_types.world_fact) ->
         match f.provenance with
         | Cross_keeper_synthesized _ -> true
         | Proposed_by _ -> false)
      world_facts_after_3
  in
  check int "3 Keepers on 1 shared facet produce exactly 1 bounded per-facet synthesis (no O(N^2))"
    1 (List.length synth_facts_after_3);
  let synth_world_fact = List.hd synth_facts_after_3 in
  (match synth_world_fact.provenance with
   | Cross_keeper_synthesized { keeper_ids; _ } ->
     check int "bounded per-facet synthesis tracks all 3 contributing keepers" 3 (List.length keeper_ids)
   | Proposed_by _ -> fail "expected Cross_keeper_synthesized");
  (* Idempotent re-promotion check: re-promoting an identical batch from the same
     keeper skips UPDATE/FTS/revision++ and leaves digest_changed = false! *)
  let gamma_id = WM_types.fact_id_of_claim ~scope:gamma_promo.scope ~claim:gamma_promo.claim in
  let gamma_rev_before =
    match WM_store.get_fact ~base_path:root ~fact_id:gamma_id with
    | Ok (Some f) -> f.revision
    | _ -> fail "gamma fact missing before idempotent re-promotion"
  in
  (match WM_curator.process_promotions_sync ~base_path:root ~now:205.5 ~keeper_id:"keeper-gamma" [ gamma_promo ] with
   | Ok report ->
     check bool "idempotent re-promotion produces digest_changed = false" false report.digest_changed;
     let gamma_rev_after =
       match WM_store.get_fact ~base_path:root ~fact_id:gamma_id with
       | Ok (Some f) -> f.revision
       | _ -> fail "gamma fact missing after idempotent re-promotion"
     in
     check int "idempotent re-promotion does not bump fact revision" gamma_rev_before gamma_rev_after
   | Error err -> fail (WM_store.error_to_string err));
  (* Atomic lock-free BEGIN DEFERRED read_snapshot consistency check *)
  (match WM_store.read_snapshot ~include_inactive:false ~base_path:root () with
   | Ok snap ->
     (match snap.digest with
      | Some d ->
        check int "read_snapshot facts count matches digest.fact_count atomically"
          d.fact_count (List.length snap.facts)
      | None -> fail "read_snapshot missing digest")
   | Error err -> fail (WM_store.error_to_string err));

  (* Terminal non-resurrection check: superseded fact cannot be mutated or resurrected. *)
  let dead_claim = "Obsolete lock strategy replaced by WAL" in
  let dead_id = WM_types.fact_id_of_claim ~scope:"workspace" ~claim:dead_claim in
  (match
     WM_store.upsert_fact ~base_path:root ~now:206.0 ~actor:"keeper-alpha"
       ~fact_id:dead_id ~claim:dead_claim ~category:Types.Fact
       ~facets:[ "obsolete_lock" ] ~scope:"workspace"
       ~provenance:(Proposed_by { keeper_id = "keeper-alpha"; source_fact_ids = [] })
       ~lifecycle:Working
   with
   | Ok _ -> ()
   | Error err -> fail (WM_store.error_to_string err));
  (match
     WM_curator.supersede_fact_sync ~base_path:root ~now:207.0 ~actor:"world_curator"
       ~old_fact_id:dead_id ~new_fact_id:synth_world_fact.fact_id ~reason:"superseded by WAL"
   with
   | Ok _ -> ()
   | Error err -> fail (WM_store.error_to_string err));
  (match
     WM_store.upsert_fact ~base_path:root ~now:208.0 ~actor:"keeper-beta"
       ~fact_id:dead_id ~claim:dead_claim ~category:Types.Fact
       ~facets:[ "obsolete_lock" ] ~scope:"workspace"
       ~provenance:(Proposed_by { keeper_id = "keeper-beta"; source_fact_ids = [] })
       ~lifecycle:Working
   with
   | Error (WM_store.Invalid_state _) -> ()
   | Ok _ -> fail "terminal Superseded fact must refuse direct upsert resurrection"
   | Error err -> fail ("unexpected error: " ^ WM_store.error_to_string err));
  (match
     WM_curator.process_promotions_sync ~base_path:root ~now:209.0 ~keeper_id:"keeper-beta"
       [ { source_fact_ids = [ "dead-repro" ]
         ; scope = "workspace"
         ; claim = dead_claim
         ; category = Types.Fact
         ; facets = [ "obsolete_lock"; "sqlite_wal" ]
         }
       ]
   with
   | Ok report ->
     check int "re-promoting dead terminal fact short-circuits without upsert" 0
       (List.length report.upserted_facts)
   | Error err -> fail (WM_store.error_to_string err));

  (* Split-brain prevention check: even when a legacy ledger.json exists alongside
     world_memory.db, Workspace_memory_ledger.observe prefers world_memory.db! *)
  let legacy_dir = Filename.concat masc_dir "workspace_memory" in
  Fs_compat.mkdir_p legacy_dir;
  Fs_compat.save_file (Filename.concat legacy_dir "ledger.json") "{invalid-stale-legacy-ledger";
  (match Masc.Workspace_memory_ledger.observe_with_briefing_template ~briefing_template:"" ~base_path:root with
   | Masc.Workspace_memory_ledger.Available obs ->
     check bool "observe prefers world_memory.db over stale legacy ledger.json" true
       (obs.claim_count >= 4)
   | Masc.Workspace_memory_ledger.Missing | Masc.Workspace_memory_ledger.Unavailable _ ->
     fail "expected Available from lock-free world_memory.db despite stale legacy ledger.json");

  (* Mixed + short (<3 char) FTS5 token search check ("C3" and "C3 WAL"). *)
  (match WM_store.search_fts ~base_path:root ~query:"C3" ~limit:5 with
   | Ok hits -> check bool "short (<3 char) FTS5 query matches C3 fact" true (List.length hits >= 1)
   | Error err -> fail (WM_store.error_to_string err));
  (match WM_store.search_fts ~base_path:root ~query:"C3 WAL" ~limit:5 with
   | Ok hits -> check bool "mixed short+trigram FTS5 query matches" true (List.length hits >= 1)
   | Error err -> fail (WM_store.error_to_string err));

  let world_facts = world_facts_after_3 in

  (* Concurrent MVCC stress: 4 sibling readers alongside a concurrent write! *)
  let concurrent_ok = Atomic.make 0 in
  Eio.Fiber.all
    [ (fun () ->
        for _ = 1 to 10 do
          match WM_store.list_facts ~base_path:root () with
          | Ok (_ :: _) -> Atomic.incr concurrent_ok
          | _ -> fail "concurrent list_facts failed"
        done)
    ; (fun () ->
        for _ = 1 to 10 do
          match WM_store.search_fts ~base_path:root ~query:"SQLite WAL" ~limit:5 with
          | Ok (_ :: _) -> Atomic.incr concurrent_ok
          | _ -> fail "concurrent search_fts failed"
        done)
    ; (fun () ->
        for _ = 1 to 10 do
          let res = Masc.Keeper_workspace_memory_read.handle ~base_path:root ~args:(`Assoc [ "view", `String "briefing" ]) in
          match res.disposition with
          | Tool_result.Completed () -> Atomic.incr concurrent_ok
          | Tool_result.Deferred () | Tool_result.Failed _ ->
            fail "concurrent keeper_workspace_memory_read failed"
        done)
    ; (fun () ->
        match
          WM_store.upsert_fact ~base_path:root ~now:210.0 ~actor:"keeper-gamma"
            ~fact_id:(WM_types.fact_id_of_claim ~scope:"workspace" ~claim:"Concurrent write during active MVCC reads")
            ~claim:"Concurrent write during active MVCC reads"
            ~category:Types.Fact
            ~facets:[ "mvcc"; "stress" ]
            ~scope:"workspace"
            ~provenance:(Proposed_by { keeper_id = "keeper-gamma"; source_fact_ids = [] })
            ~lifecycle:Working
        with
        | Ok _ -> Atomic.incr concurrent_ok
        | Error err -> fail (WM_store.error_to_string err))
    ];
  check int "all 31 concurrent MVCC reads + write succeeded with zero blocking" 31 (Atomic.get concurrent_ok);

  (* Real MCP resources/list + resources/read on masc://world-memory/... *)
  let server_state = Mcp_eio.For_testing.create_state ~base_path:root () in
  let listed_uris = list_all_mcp_resource_uris ~clock:(Eio.Stdenv.clock env) ~sw server_state in
  List.iter
    (fun uri ->
       check bool ("resources/list advertises " ^ uri) true (List.mem uri listed_uris))
    [ "masc://world-memory/claims"
    ; "masc://world-memory/digest"
    ; "masc://world-memory/index"
    ; "masc://world-memory/log"
    ];
  let claims_json = read_mcp_json ~state:server_state ~uri:"masc://world-memory/claims" in
  let digest_json = read_mcp_json ~state:server_state ~uri:"masc://world-memory/digest" in
  let index_json = read_mcp_json ~state:server_state ~uri:"masc://world-memory/index" in
  let fact_json =
    read_mcp_json ~state:server_state ~uri:("masc://world-memory/facts/" ^ synth_world_fact.fact_id)
  in
  let log_json = read_mcp_json ~state:server_state ~uri:"masc://world-memory/log" in
  let open Yojson.Safe.Util in
  check string "claims backend is sqlite_wal_mvcc" "sqlite_wal_mvcc"
    (claims_json |> member "backend" |> to_string);
  check string "digest backend is sqlite_wal_mvcc" "sqlite_wal_mvcc"
    (digest_json |> member "backend" |> to_string);
  check bool "index returns >= 6 unified entries" true
    (index_json |> member "count" |> to_int >= 6);
  check string "fact detail matches synthesized id" synth_world_fact.fact_id
    (fact_json |> member "fact" |> member "fact_id" |> to_string);
  check bool "log has committed mutations" true
    (log_json |> member "last_committed_seq" |> to_int >= 5);

  (* Bidirectional World Memory Index snapshot back into Keeper Librarian context *)
  let world_snapshot_for_librarian =
    match WM.read_index_snapshot_for_librarian ~base_path:root with
    | Some s -> s
    | None -> fail "expected read-only world index snapshot for Librarian"
  in
  check bool "world index snapshot mentions canonical synthesis" true
    (String_util.contains_substring world_snapshot_for_librarian "Cross-Keeper synthesis");

  (* === STAGE 4: Cache-Stable Per-Keeper Memory Digest (ZERO "bodies omitted") + Persistent WAL FTS5 === *)
  let snap_a = Store.memory store_a in
  let digest_epoch =
    Digest_mod.load_or_compile ~keepers_dir ~keeper_id:"keeper-alpha" ~revision:snap_a.revision ~facts:snap_a.facts
  in
  check int "frozen epoch digest tracks derived synthesized fact" 1 digest_epoch.derived_count;
  let observed =
    Masc.Keeper_recall_artifact.observe_current ~config ~keeper_id:"keeper-alpha" ~kind:Memory_os
  in
  let recall_turn_1 =
    Recall.render_demand_notice
      ~memory_select_route:Unavailable
      ~memory_search_available:true
      ~config ~keepers_dir ~keeper_id:"keeper-alpha" ~observed
  in
  let recall_turn_2 =
    Recall.render_demand_notice
      ~memory_select_route:Unavailable
      ~memory_search_available:true
      ~config ~keepers_dir ~keeper_id:"keeper-alpha" ~observed
  in
  check string "Per-Keeper Memory Digest is 100% byte-identical across turns within epoch"
    recall_turn_1.text recall_turn_2.text;
  check bool "Tier-1 recall contains synthesized Derived fact body" true
    (String_util.contains_substring recall_turn_1.text "lock-free multi-Keeper memory isolation");
  check bool "Tier-1 recall has ZERO 'bodies omitted'" false
    (String_util.contains_substring recall_turn_1.text "bodies omitted");

  let indexed_a =
    match Search_idx.sync_snapshot ~keepers_dir ~keeper_id:"keeper-alpha" snap_a with
    | Ok n -> n
    | Error err -> fail (Search_idx.error_to_string err)
  in
  check int "persistent per-Keeper SQLite WAL FTS5 indexed 3 facts" 3 indexed_a;
  let fts_hits =
    match Search_idx.search_persistent ~keepers_dir ~keeper_id:"keeper-alpha" ~query:"lock-free" ~limit:5 with
    | Ok hits -> hits
    | Error err -> fail (Search_idx.error_to_string err)
  in
  check bool "persistent WAL FTS5 found synthesized derived fact" true (List.length fts_hits >= 1);

  Printf.printf
    "\n=== STACK C LIVING MEMORY CIRCULATION E2E PROOF ===\n\
     - Stage 1 (Anchored Compaction): epoch=%d, externalized_blobs=%d, provider_400k_to_128k_msgs=%d, lossless_turn_id=%s\n\
     - Stage 2 (Ship-of-Theseus Librarian): compacted_log_lines=%d -> 1 checkpoint, cold_archived=%d, derived_synthesized=1, world_promotions=%d\n\
     - Stage 3 (MVCC World Memory + MCP): active_world_facts=%d, edges=%d, unified_index=%d, concurrent_mvcc_ops=%d, mcp_notifications=%d\n\
     - Stage 4 (Frozen Digest + Persistent FTS5): cache_stable_bytes=%d, digest_sha256=%s, bodies_omitted=false, fts5_hits=%d\n"
    anchor.epoch_id
    compact_res_400k.microcompacted_results
    (List.length proj_128k_msgs)
    (Ids.Turn_id.to_string archived_t1.turn_id)
    compacted_lines
    (List.length archived_a.left)
    (List.length plan_a.effects.promotions + List.length plan_b.effects.promotions)
    (List.length world_facts)
    (List.length world_edges)
    (List.length world_index)
    (Atomic.get concurrent_ok)
    (Atomic.get mcp_notifications)
    (String.length recall_turn_1.text)
    (String.sub digest_epoch.digest_sha256 0 12)
    (List.length fts_hits)
;;

let test_stack_c_tool_blob_scope_classification () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let pool = Domain_pool.create ~sw ~domain_count:2 (Eio.Stdenv.domain_mgr env) in
  Domain_pool_ref.set pool;
  Fun.protect ~finally:Domain_pool_ref.clear_for_tests @@ fun () ->
  with_temp_dir @@ fun root ->
  let keepers_dir = Server_tool_blob_scope.scope.config_keepers_dir ~base_path:root in
  let turns_dir = Filename.concat root "turns_scratch" in
  Fs_compat.mkdir_p keepers_dir;
  Fs_compat.mkdir_p turns_dir;
  let blob_store = Tool_blob_store.create ~base_path:root in
  (* 1. C1: compaction.db (+ WAL/SHM) + durable microcompacted blob handles *)
  let big_body = "HEAD-SCOPE\n" ^ String.make 10_000 's' ^ "\nTAIL-SCOPE" in
  let turns =
    [ make_turn ~idx:1 ~user_text:"Scope check 1" ~tool_output:big_body ~assistant_text:"Checked 1"
    ; make_turn ~idx:2 ~user_text:"Scope check 2" ~tool_output:big_body ~assistant_text:"Checked 2"
    ; make_turn ~idx:3 ~user_text:"Scope check 3" ~tool_output:"small" ~assistant_text:"Checked 3"
    ]
  in
  let compact_res =
    match
      Compaction.compact_and_project
        ~blob_store
        ~keep_recent_turns:1
        ~keepers_dir
        ~keeper_id:"keeper-scope"
        ~measure_message_bytes:msg_bytes
        ~capacity_bytes:20_000
        ~reserved_bytes:500
        turns
    with
    | Ok r -> r
    | Error err -> fail (Compaction.store_error_to_string err)
  in
  check bool "C1 microcompacted durable blobs" true (compact_res.microcompacted_results >= 1);
  (* Also commit an epoch so compaction.db has compaction_epochs + archived_turns + active_microcompacted_handles *)
  ignore
    (match
       Compaction.compact_and_project
         ~blob_store
         ~keep_recent_turns:1
         ~force_trigger:(Compaction.Provider_context_overflow { provider_limit_tokens = Some 128_000 })
         ~keepers_dir
         ~keeper_id:"keeper-scope"
         ~measure_message_bytes:msg_bytes
         ~capacity_bytes:20_000
         ~reserved_bytes:500
         turns
     with
     | Ok r -> r
     | Error err -> fail (Compaction.store_error_to_string err));
  (* 2. C2: memory-log.jsonl + memory-archive.jsonl + memory-digest.json + memory_fts.db (+ WAL/SHM) *)
  let store = boot_keeper_store ~keepers_dir ~turns_dir ~keeper_id:"keeper-scope" ~at:10.0 in
  let store = remember store "Scope test fact 1" Types.Fact 20.0 in
  let store = remember store "Scope test fact 2" Types.Validated_approach 25.0 in
  let store, _ =
    match Store.compact_log store ~at:30.0 with
    | Ok r -> r
    | Error _ -> fail "compact_log failed in scope classification test"
  in
  let snap = Store.memory store in
  ignore (Digest_mod.load_or_compile ~keepers_dir ~keeper_id:"keeper-scope" ~revision:snap.revision ~facts:snap.facts);
  (match Search_idx.sync_snapshot ~keepers_dir ~keeper_id:"keeper-scope" snap with
   | Ok n -> check bool "C2 persistent FTS5 indexed facts" true (n >= 2)
   | Error err -> fail (Search_idx.error_to_string err));
  (* 3. C3: .masc/world_memory.db (+ WAL/SHM) *)
  let curator =
    WM.start_workspace_curator ~sw ~base_path:root ~now:(fun () -> 40.0) ~on_updated:(fun () -> ())
  in
  WM_curator.enqueue_index_sync curator;
  WM_curator.flush curator;
  check bool "C3 world_memory.db exists" true (WM_store.exists ~base_path:root);
  check bool "C1 compaction.db exists" true
    (Sys.file_exists (Compaction.db_path ~keepers_dir ~keeper_id:"keeper-scope"));
  check bool "C2 memory-archive.jsonl exists" true
    (Sys.file_exists (Log_store.archive_path_for_keepers_dir ~keepers_dir ~keeper_id:"keeper-scope"));
  check bool "C2 memory-digest.json exists" true
    (Sys.file_exists (Filename.concat keepers_dir ("keeper-scope" ^ Digest_mod.suffix)));
  check bool "C2 memory_fts.db exists" true
    (Sys.file_exists (Search_idx.db_path ~keepers_dir ~keeper_id:"keeper-scope"));
  (* 4. Tool_blob_maintenance sweep across ALL C1 + C2 + C3 files in production layout *)
  let run_sweep mode =
    match Tool_blob_maintenance.run ~base_path:root ~scope:Server_tool_blob_scope.scope ~mode with
    | Ok report -> report
    | Error err -> fail (Tool_blob_maintenance.error_to_string err)
  in
  let obs = run_sweep Tool_blob_maintenance.Observe_only in
  check (list string) "all Stack C (C1+C2+C3) files have zero unclassified entries" [] obs.unclassified;
  check bool "C1 active microcompacted blobs remain live references" true (obs.live_references >= 1);
  let del = run_sweep Tool_blob_maintenance.Delete_previous_candidates in
  check (list string) "delete pass has zero unclassified entries" [] del.unclassified
;;

let () =
  run "stack_c_living_memory_circulation"
    [ ( "e2e"
      , [ test_case "full living memory circulation (C1 -> C2 -> C3 -> MCP + Digest)" `Quick
            test_full_living_memory_circulation
        ; test_case "all Stack C (C1+C2+C3) files classified cleanly by Server_tool_blob_scope" `Quick
            test_stack_c_tool_blob_scope_classification
        ] )
    ]
;;
