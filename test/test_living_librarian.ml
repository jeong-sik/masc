open Alcotest
module Types = Masc.Keeper_memory_os_types
module Current = Masc.Keeper_memory_os_current_types
module Answer = Masc.Librarian_answer
module Effects = Masc.Librarian_effects
module Lifecycle = Masc.Librarian_lifecycle
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
      (Printf.sprintf "masc-living-librarian-%d-%d" (Unix.getpid ()) (Random.int 1_000_000))
  in
  Unix.mkdir base 0o700;
  Fun.protect ~finally:(fun () -> rm_rf base) (fun () -> f base)
;;

let asked =
  match
    Question_id.of_halves ~front:(String.make 32 '1') ~back:(String.make 32 '2')
  with
  | Some id -> id
  | None -> fail "bad question id"
;;

let fact ~category claim : Types.fact =
  { claim
  ; category
  ; first_seen = 100.0
  ; last_seen = 100.0
  ; origin = { kind = Authored; trace_id = "t-1" }
  ; basis = Observed Transcript
  }
;;

let test_lifecycle_transitions () =
  let ok_tr from to_ =
    match Lifecycle.transition ~from ~to_ with
    | Ok next -> check string "lifecycle token" (Lifecycle.lifecycle_to_string to_) (Lifecycle.lifecycle_to_string next)
    | Error err -> fail (Lifecycle.invalid_transition_to_string err)
  in
  let err_tr from to_ =
    match Lifecycle.transition ~from ~to_ with
    | Ok _ ->
      failf "expected rejection for %s -> %s"
        (Lifecycle.lifecycle_to_string from) (Lifecycle.lifecycle_to_string to_)
    | Error _ -> ()
  in
  ok_tr Ephemeral Working;
  ok_tr Working Consolidated;
  ok_tr Consolidated Canonical;
  ok_tr Canonical (Superseded_by "sha256:next");
  ok_tr Working Molted_to_archive;
  err_tr Ephemeral Canonical;
  err_tr Canonical Working;
  err_tr Molted_to_archive Working;
  err_tr (Superseded_by "sha256:next") Consolidated
;;

let test_derived_synthesize_molt_promote () =
  let f1 = fact ~category:Constraint "SQLite WAL readers never take workspace-global locks" in
  let f2 = fact ~category:Validated_approach "Domain_pool isolates SQLite I/O from the main Eio domain" in
  let f3 = fact ~category:Fact "Temporary build cache warmed during turn 4" in
  let facts = [ f1; f2; f3 ] in
  let memory =
    [ "m1", Types.memory_id f1
    ; "m2", Types.memory_id f2
    ; "m3", Types.memory_id f3
    ]
  in
  let shown : Plan.shown =
    Molt { memory; trigger = Compaction_epoch_advanced { epoch_id = 3 } }
  in
  let answer : Answer.t =
    { question = asked
    ; working_state = Set "epoch 3 consolidated"
    ; ops =
        [ Synthesize
            { refs = [ "m1"; "m2" ]
            ; claim = "Off-domain SQLite WAL guarantees non-blocking concurrent Keeper memory access"
            ; category = Lesson
            ; rule_id = "cross_category_synthesis"
            ; from_units = []
            }
        ; Molt { refs = [ "m3" ]; reason = "ephemeral turn-4 build cache superseded by compaction epoch 3" }
        ; Promote_to_world
            { refs = [ "m1"; "m2" ]
            ; scope = "workspace"
            ; claim = "MASC memory stores run SQLite WAL strictly on Domain_pool without global flock"
            ; category = Validated_approach
            ; facets = [ "sqlite_wal"; "domain_pool"; "concurrency" ]
            }
        ]
    }
  in
  (* Verify JSON wire round-trip of all evolutionary ops. *)
  let encoded = Yojson.Safe.to_string (Answer.to_json answer) in
  (match Answer.of_string ~asked encoded with
   | Ok decoded ->
     check string "answer round-trip" encoded (Yojson.Safe.to_string (Answer.to_json decoded))
   | Error rej -> failf "answer round-trip failed: %s" (Answer.rejection_kind rej));
  let plan =
    Plan.of_answer ~shown ~facts ~removed_since:[] ~at:250.0 ~trace_id:"molt-3" answer
  in
  check int "zero ops refused" 0 (List.length plan.effects.not_applied);
  check int "1 synthesized derived fact added" 1 (List.length plan.effects.added);
  let synth = List.hd plan.effects.added in
  (match synth.basis with
   | Derived [ deriv ] ->
     check string "rule_id" "cross_category_synthesis" deriv.rule_id;
     check int "2 premises" 2 (List.length deriv.premise_ids)
   | _ -> fail "expected Derived basis with 1 derivation");
  check int "1 ephemeral fact molted" 1 (List.length plan.effects.removed);
  (match snd (List.hd plan.effects.removed) with
   | Effects.Molted { reason } ->
     check bool "molt reason present" true (String.length reason > 0)
   | _ -> fail "expected Molted removal");
  check int "1 world promotion emitted" 1 (List.length plan.effects.promotions);
  let promo = List.hd plan.effects.promotions in
  check string "promotion scope" "workspace" promo.scope;
  check int "promotion has 2 source fact ids" 2 (List.length promo.source_fact_ids);
  check int "3 facts remain (2 premises + 1 derived)" 3 (List.length plan.facts)
;;

let test_checkpoint_compaction_and_digest_and_fts () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let pool = Domain_pool.create ~sw ~domain_count:2 (Eio.Stdenv.domain_mgr env) in
  Domain_pool_ref.set pool;
  Fun.protect ~finally:Domain_pool_ref.clear_for_tests @@ fun () ->
  with_temp_dir @@ fun root ->
  let keepers_dir = Filename.concat root "keepers" in
  let turns_dir = Filename.concat root "turns" in
  Unix.mkdir keepers_dir 0o700;
  Unix.mkdir turns_dir 0o700;
  let keeper_id = "keeper-living" in
  let turns_path = Turn_store.path_for_keepers_dir ~keepers_dir:turns_dir ~keeper_id in
  let log_id =
    match Turn_log.Log_id.of_string (String.make 32 'a') with
    | Some id -> id
    | None -> fail "bad log id"
  in
  let mark : Turn_log.mark =
    { trace = "t-0"
    ; closed_messages = 0
    ; session = ""
    ; history_bytes = 0
    ; internal_bytes = 0
    ; chat_bytes = 0
    ; external_rows = 0
    }
  in
  (match Turn_store.append ~path:turns_path ~at_end:0 (Turn_log.Log_started { id = log_id; at = 10.0; mark }, []) with
   | Ok _ -> ()
   | Error _ -> fail "failed to start turn log");
  let store =
    match Store.boot ~memory_dir:keepers_dir ~turns_dir ~keeper_id ~at:20.0 with
    | Ok s -> s
    | Error _ -> fail "store boot failed"
  in
  (* Commit 3 facts via direct writes, then molt one & synthesize one, then compact log. *)
  let remember store claim category at =
    let write = Masc.Librarian_direct.Remember { claim; category; basis = Observed Transcript } in
    match Masc.Librarian_direct.plan ~by:Keeper ~at ~trace_id:"t-w" (Store.memory store).facts write with
    | Writes { effects; _ } ->
      (match Store.commit_direct store ~at ~by:Keeper ~trace:"t-w" write effects with
       | Committed { store; _ } -> store
       | _ -> fail "commit_direct failed")
    | _ -> fail "direct plan failed"
  in
  let store = remember store "Compaction uses immutable Turn_id anchors" Types.Constraint 30.0 in
  let store = remember store "SQLite WAL runs off-domain on Domain_pool" Types.Validated_approach 40.0 in
  let store = remember store "Scratch diagnostic counter was 7" Types.Fact 50.0 in
  let facts = (Store.memory store).facts in
  let memory = List.mapi (fun i f -> Printf.sprintf "m%d" (i + 1), Types.memory_id f) facts in
  let molt_answer : Answer.t =
    { question = asked
    ; working_state = Keep
    ; ops =
        [ Synthesize
            { refs = [ "m1"; "m2" ]
            ; claim = "Anchored compaction and off-domain SQLite WAL form a lossless non-blocking loop"
            ; category = Lesson
            ; rule_id = "architecture_synthesis"
            ; from_units = []
            }
        ; Molt { refs = [ "m3" ]; reason = "ephemeral scratch counter shed at compaction epoch 1" }
        ; Promote_to_world
            { refs = [ "m1"; "m2" ]
            ; scope = "workspace"
            ; claim = "Compaction and off-domain WAL run lock-free"
            ; category = Validated_approach
            ; facets = [ "compaction"; "sqlite_wal" ]
            }
        ]
    }
  in
  let plan =
    Plan.of_answer
      ~shown:(Molt { memory; trigger = Compaction_epoch_advanced { epoch_id = 1 } })
      ~facts ~removed_since:[] ~at:60.0 ~trace_id:"molt-1" molt_answer
  in
  let q : Masc.Librarian_room_result.question =
    { id = asked
    ; memory
    ; basis = Masc.Librarian_log.snapshot_after (Store.tail store)
    ; trace = "molt-1"
    }
  in
  let store =
    match
      Store.commit_molt store ~at:60.0 ~question:q ~slot:"slot.living"
        ~trigger:(Compaction_epoch_advanced { epoch_id = 1 }) plan
    with
    | Committed { store; _ } -> store
    | _ -> fail "commit_molt failed"
  in
  (* Compact the commit log and verify line count shrinks to 1 while archive stays intact! *)
  let log_path = Log_store.path_for_keepers_dir ~keepers_dir ~keeper_id in
  let store_after_compact, compacted_lines =
    match Store.compact_log store ~at:70.0 with
    | Ok res -> res
    | Error _ -> fail "compact_log failed"
  in
  check bool "compacted multiple log lines" true (compacted_lines >= 4);
  let lines_after =
    match Log_store.fold log_path ~init:0 ~f:(fun n _ -> n + 1) with
    | Ok n -> n
    | Error _ -> fail "fold after compact failed"
  in
  check int "live log shrunk to 1 checkpoint baseline line" 1 lines_after;
  check bool "post-compact store preserves last_promotions for world dispatch" true
    (Option.is_some (Store.last_promotions store_after_compact));
  let archived =
    match Archive.read log_path ~current:(Store.memory store_after_compact).facts with
    | Ok a -> a
    | Error _ -> fail "archive read failed"
  in
  check int "cold archive preserves molted fact" 1 (List.length archived.left);
  check string "archived claim matches" "Scratch diagnostic counter was 7"
    (List.hd archived.left).fact.claim;
  (* Verify store re-boots cleanly from compacted single-line checkpoint log. *)
  (match Store.boot ~memory_dir:keepers_dir ~turns_dir ~keeper_id ~at:75.0 with
   | Ok rebooted ->
     check int "rebooted snapshot fact count" 3 (List.length (Store.memory rebooted).facts)
   | Error _ -> fail "reboot after compact_log failed");
  (* Verify frozen-epoch Per-Keeper Memory Digest + ZERO "bodies omitted". *)
  let snap = Store.memory store_after_compact in
  let d1 = Digest_mod.load_or_compile ~keepers_dir ~keeper_id ~revision:snap.revision ~facts:snap.facts in
  let d2 = Digest_mod.load_or_compile ~keepers_dir ~keeper_id ~revision:snap.revision ~facts:snap.facts in
  check string "digest is byte-identical across turns within same epoch" d1.rendered d2.rendered;
  check int "digest derived count" 1 d1.derived_count;
  check bool "digest contains derived claim" true
    (String_util.string_contains_substring ~needle:"lossless non-blocking loop" d1.rendered);
  check bool "zero bodies omitted in digest" false
    (String_util.string_contains_substring ~needle:"bodies omitted" d1.rendered);
  (* Bounded Tier-1 digest enforces deterministic byte ceiling with overflow pointer *)
  let d_bounded =
    Digest_mod.compile_bounded ~max_bytes:380 ~keeper_id ~revision:snap.revision ~facts:snap.facts
  in
  check bool "bounded digest includes overflow search pointer" true
    (String_util.string_contains_substring ~needle:"keeper_memory_search" d_bounded.rendered);
  check bool "bounded digest prioritizes Derived fact first" true
    (String_util.string_contains_substring ~needle:"lossless non-blocking loop" d_bounded.rendered);
  let config = Masc.Workspace.default_config root in
  let observed =
    Masc.Keeper_recall_artifact.observe_current ~config ~keeper_id ~kind:Memory_os
  in
  let rendered_recall =
    Recall.render_demand_notice
      ~memory_select_route:Unavailable
      ~memory_search_available:true
      ~config ~keepers_dir ~keeper_id ~observed
  in
  check bool "recall contains actual digest fact body" true
    (String_util.string_contains_substring ~needle:"lossless non-blocking loop" rendered_recall.text);
  check bool "recall has ZERO 'bodies omitted'" false
    (String_util.string_contains_substring ~needle:"bodies omitted" rendered_recall.text);
  (* Verify Persistent SQLite WAL FTS5 search + concurrent Domain_pool reads. *)
  let indexed =
    match Search_idx.sync_snapshot ~keepers_dir ~keeper_id snap with
    | Ok n -> n
    | Error e -> fail (Search_idx.error_to_string e)
  in
  check int "3 facts indexed in persistent WAL FTS5" 3 indexed;
  let hits_a, hits_b =
    Eio.Fiber.pair
      (fun () -> Search_idx.search_persistent ~keepers_dir ~keeper_id ~query:"lossless" ~limit:5)
      (fun () -> Search_idx.search_persistent ~keepers_dir ~keeper_id ~query:"Domain_pool" ~limit:5)
  in
  (match hits_a, hits_b with
   | Ok ha, Ok hb ->
     check bool "lossless hit found" true (List.length ha >= 1);
     check bool "Domain_pool hit found" true (List.length hb >= 1)
   | _ -> fail "concurrent persistent WAL FTS5 reads failed");
  (* rank_persistent_for_facts reuses synced index on RO MVCC path without revision-0 thrashing *)
  (match Search_idx.rank_persistent_for_facts ~keepers_dir ~keeper_id ~query:"lossless" snap.facts with
   | Ok (_ :: _) -> ()
   | Ok [] -> fail "rank_persistent_for_facts returned no hits"
   | Error e -> fail (Search_idx.error_to_string e))
;;

let test_promotion_only_plan_commits_without_fact_change () =
  with_temp_dir @@ fun root ->
  let keepers_dir = Filename.concat root "keepers" in
  let turns_dir = Filename.concat root "turns" in
  Unix.mkdir keepers_dir 0o700;
  Unix.mkdir turns_dir 0o700;
  let keeper_id = "keeper-promo-only" in
  let turns_path = Turn_store.path_for_keepers_dir ~keepers_dir:turns_dir ~keeper_id in
  let log_id =
    match Turn_log.Log_id.of_string (String.make 32 'b') with
    | Some id -> id
    | None -> fail "bad log id"
  in
  let mark : Turn_log.mark =
    { trace = "t-0"
    ; closed_messages = 0
    ; session = ""
    ; history_bytes = 0
    ; internal_bytes = 0
    ; chat_bytes = 0
    ; external_rows = 0
    }
  in
  (match Turn_store.append ~path:turns_path ~at_end:0 (Turn_log.Log_started { id = log_id; at = 10.0; mark }, []) with
   | Ok _ -> ()
   | Error _ -> fail "failed to start turn log");
  let store =
    match Store.boot ~memory_dir:keepers_dir ~turns_dir ~keeper_id ~at:20.0 with
    | Ok s -> s
    | Error _ -> fail "store boot failed"
  in
  let write =
    Masc.Librarian_direct.Remember
      { claim = "SQLite WAL readers never take global flock"
      ; category = Types.Constraint
      ; basis = Observed Transcript
      }
  in
  let store =
    match Masc.Librarian_direct.plan ~by:Keeper ~at:30.0 ~trace_id:"t-1" (Store.memory store).facts write with
    | Writes { effects; _ } ->
      (match Store.commit_direct store ~at:30.0 ~by:Keeper ~trace:"t-1" write effects with
       | Committed { store; _ } -> store
       | _ -> fail "commit_direct failed")
    | _ -> fail "direct plan failed"
  in
  let rev_before = (Store.memory store).revision in
  let facts = (Store.memory store).facts in
  let memory = List.mapi (fun i f -> Printf.sprintf "m%d" (i + 1), Types.memory_id f) facts in
  let promo_only_answer : Answer.t =
    { question = asked
    ; working_state = Keep
    ; ops =
        [ Promote_to_world
            { refs = [ "m1" ]
            ; scope = "workspace"
            ; claim = "MASC memory stores run SQLite WAL without global flock"
            ; category = Constraint
            ; facets = [ "sqlite_wal"; "concurrency" ]
            }
        ]
    }
  in
  let plan =
    Plan.of_answer
      ~shown:(Molt { memory; trigger = Compaction_epoch_advanced { epoch_id = 1 } })
      ~facts ~removed_since:[] ~at:40.0 ~trace_id:"molt-promo-only" promo_only_answer
  in
  check bool "fact snapshot unchanged" false (Masc.Librarian_envelope.changes_facts plan.effects);
  check int "1 promotion planned" 1 (List.length plan.effects.promotions);
  check bool "Store.changes returns true for promotion-only plan" true (Store.changes store plan);
  let q : Masc.Librarian_room_result.question =
    { id = asked
    ; memory
    ; basis = Masc.Librarian_log.snapshot_after (Store.tail store)
    ; trace = "molt-promo-only"
    }
  in
  match
    Store.commit_molt store ~at:40.0 ~question:q ~slot:"slot.promo"
      ~trigger:(Compaction_epoch_advanced { epoch_id = 1 }) plan
  with
  | Committed { store = store_after; line } ->
    check int "snapshot revision preserved when facts unchanged" rev_before
      (Store.memory store_after).revision;
    (match Store.last_promotions store_after with
     | Some (seq, [ promo ]) ->
       check int "last_promotions seq matches commit line" line.seq seq;
       check string "promoted scope" "workspace" promo.scope
     | _ -> fail "expected committed promotion in Store.last_promotions")
  | Committed_without_snapshot _ | Not_a_snapshot _ | Stopped _ ->
    fail "promotion-only commit_molt failed"
;;

let () =
  run "living_librarian"
    [ "lifecycle", [ test_case "declarative state transitions" `Quick test_lifecycle_transitions ]
    ; ( "evolution"
      , [ test_case "derived synthesize + molt + promote_to_world" `Quick
            test_derived_synthesize_molt_promote
        ; test_case "checkpoint compaction + frozen digest + persistent WAL FTS5" `Quick
            test_checkpoint_compaction_and_digest_and_fts
        ; test_case "promotion-only molt plan commits via Store.changes" `Quick
            test_promotion_only_plan_commits_without_fact_change
        ] )
    ]
;;
