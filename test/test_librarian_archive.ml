(* The facts that left a Keeper's Memory, read from its commit log
   (RFC librarian-call-only-proposes §11.5). The log of every case is written
   by the store itself, through the writes a Keeper makes. *)

open Alcotest
module Archive = Masc.Librarian_archive
module Machine = Masc.Librarian_machine
module Store = Masc.Librarian_store
module Log_store = Masc.Librarian_log_store
module Direct = Masc.Librarian_direct
module Effects = Masc.Librarian_effects
module Types = Masc.Keeper_memory_os_types
module Turn_log = Masc.Keeper_turn_log
module Turn_store = Masc.Keeper_turn_log_store

let keeper_id = "keeper-a"

let turn_log =
  match Turn_log.Log_id.of_string (String.make 32 'a') with
  | Some id -> id
  | None -> fail "the test log id is not 32 hexadecimal characters"
;;

let mark : Turn_log.mark =
  { trace = "trace-1"
  ; closed_messages = 0
  ; session = ""
  ; history_bytes = 0
  ; internal_bytes = 0
  ; chat_bytes = 0
  ; external_rows = 0
  }
;;

(* A place whose Keeper has a turn log and nothing else. *)
let started_place () : Machine.place =
  let place : Machine.place =
    { memory_dir = Filename.temp_dir "memory" ""
    ; turns_dir = Filename.temp_dir "turns" ""
    ; keeper_id
    }
  in
  match
    Turn_store.append
      ~path:(Turn_store.path_for_keepers_dir ~keepers_dir:place.turns_dir ~keeper_id)
      ~at_end:0
      (Turn_log.Log_started { id = turn_log; at = 50.0; mark }, [])
  with
  | Ok (_ : Turn_store.appended) -> place
  | Error (_ : Turn_store.append_error) -> fail "the turn log of the fixture was not written"
;;

let log_path (place : Machine.place) =
  Log_store.path_for_keepers_dir ~keepers_dir:place.memory_dir ~keeper_id
;;

let memory (value : Machine.t) =
  match value.state with
  | Idle { store; seen_length = (_ : int option) } -> (Store.memory store).facts
  | Asking _ | Resting _ | Refused_at_bottom _ | Stopped _ ->
    fail "the store of the fixture is not idle"
;;

(* A write that has to commit a line. *)
let write place state ~at w =
  match Machine.write place state ~at ~by:Effects.Keeper ~trace:"turn" w with
  | state, Written (_ : Masc.Librarian_log.commit) -> state
  | ( (_ : Machine.t)
    , (Already_held | Already_done | Already_absent | Refused _ | Not_a_snapshot _ | Unavailable _)
    ) -> fail "the write of the fixture was not committed"
;;

let id_of_claim = Types.memory_id_of_claim
let transcript = Types.Observed Types.Transcript
let remember claim = Direct.Remember { claim; category = Types.Constraint; basis = transcript }
let port = "the port is 8935"
let owner = "the owner is the release team"
let new_owner = "the owner is the platform team"
let rests = "requests go to 8935"

let removal_text : Effects.removal -> string = function
  | Dropped { reason } -> "dropped: " ^ reason
  | Merged_into successor -> "merged into " ^ successor
  | Revised_into successor -> "revised into " ^ successor
  | Superseded_by successor -> "superseded by " ^ successor
  | Retracted { by = Keeper; reason } -> "retracted by the keeper: " ^ reason
  | Retracted { by = Operator operator; reason } -> "retracted by " ^ operator ^ ": " ^ reason
  | Support_lost { missing } -> "support lost: " ^ String.concat "," missing
  | Molted { reason } -> "molted: " ^ reason
;;

let archive_text place ~current =
  match Archive.read (log_path place) ~current with
  | Error error -> [ Masc.Private_jsonl_scan.error_to_string error ], 0
  | Ok { left; unreadable } ->
    ( List.map
        (fun (left : Archive.left) -> left.fact.claim ^ " -> " ^ removal_text left.removal)
        left
    , unreadable )
;;

(* Three facts, the third derived from the first. Then the first is
   retracted and the second superseded. *)
let after_two_removals place =
  let state =
    Machine.booted place ~at:100.0 ~lane:None ~last_ask:0 (Machine.boot place ~at:100.0)
  in
  let state = write place state ~at:201.0 (remember port) in
  let state = write place state ~at:202.0 (remember owner) in
  let state =
    write place state ~at:203.0
      (Direct.Remember
         { claim = rests
         ; category = Types.Lesson
         ; basis = Types.Derived [ { rule_id = "rule"; premise_ids = [ id_of_claim port ] } ]
         })
  in
  let state =
    write place state ~at:204.0 (Direct.Retract { id = id_of_claim port; reason = "the port moved" })
  in
  write place state ~at:205.0
    (Direct.Supersede
       { old = id_of_claim owner; claim = new_owner; category = Types.Constraint; basis = transcript })
;;

let all_three =
  [ port ^ " -> retracted by the keeper: the port moved"
  ; rests ^ " -> support lost: " ^ id_of_claim port
  ; owner ^ " -> superseded by " ^ id_of_claim new_owner
  ]
;;

let test_what_left_and_why () =
  let place = started_place () in
  check (pair (list string) int) "no log is no fact" ([], 0) (archive_text place ~current:[]);
  let state = after_two_removals place in
  check (pair (list string) int) "in the order they left, each with what removed it"
    (all_three, 0)
    (archive_text place ~current:(memory state));
  match Archive.read (log_path place) ~current:(memory state) with
  | Ok { left = first :: _; _ } ->
    check (float 0.0) "when the line that removed it was committed" 204.0 first.at;
    check bool "the fact as Memory held it" true (Float.equal first.fact.first_seen 201.0)
  | Ok { left = []; _ } | Error _ -> fail "the first fact that left is not there"
;;

let test_a_fact_added_again_is_not_left () =
  let place = started_place () in
  let state = after_two_removals place in
  let state = write place state ~at:206.0 (remember port) in
  check (pair (list string) int) "the port is held again"
    ( [ rests ^ " -> support lost: " ^ id_of_claim port
      ; owner ^ " -> superseded by " ^ id_of_claim new_owner
      ]
    , 0 )
    (archive_text place ~current:(memory state))
;;

(* A snapshot an operator adopted can hold a fact the log last saw leaving. *)
let test_a_fact_the_snapshot_holds_is_not_left () =
  let place = started_place () in
  let state = after_two_removals place in
  let adopted =
    match Archive.read (log_path place) ~current:[] with
    | Ok { left; _ } ->
      List.filter_map
        (fun (left : Archive.left) ->
           if String.equal left.fact.claim owner then Some left.fact else None)
        left
    | Error _ -> fail "the archive of the fixture was not read"
  in
  check int "the fixture found the fact" 1 (List.length adopted);
  check (pair (list string) int) "what Memory holds now has not left"
    ( [ port ^ " -> retracted by the keeper: the port moved"
      ; rests ^ " -> support lost: " ^ id_of_claim port
      ]
    , 0 )
    (archive_text place ~current:(memory state @ adopted))
;;

let test_lines_that_do_not_decode_are_counted () =
  let place = started_place () in
  let state = after_two_removals place in
  Out_channel.with_open_gen [ Open_wronly; Open_append; Open_binary ] 0o600 (log_path place)
    (fun channel -> Out_channel.output_string channel "not json\n");
  check (pair (list string) int) "the rest is read, and the count says one line is not known"
    (all_three, 1)
    (archive_text place ~current:(memory state))
;;

let test_memory_diff_through_compaction () =
  let module Diff = Masc.Librarian_history_diff in
  let place = started_place () in
  let state = after_two_removals place in
  let current = memory state in
  let store = match state.state with
    | Idle { store; _ } -> store
    | Asking _ | Resting _ | Refused_at_bottom _ | Stopped _ -> fail "fixture did not settle" in
  let revision = (Store.memory store).revision in
  let path = log_path place in
  let read () = match Archive.history path with
    | Ok h -> h | Error e -> fail (Masc.Private_jsonl_scan.error_to_string e) in
  let project range = Diff.project ~range ~current ~revision (read ()) in
  let time = Diff.Time (200., 205.) in
  let before = project time in
  let links d = List.filter_map (function
    | (p : Diff.position), Diff.Updated u -> Some (p.seq, p.revision, p.at, Types.memory_id u.before,
                                                    Types.memory_id u.after, u.body_source)
    | _, (Diff.Removed _ | Diff.Added _ | Diff.Successor_unavailable _) -> None) d.Diff.events in
  let initial_links = links before in
  check int "live fixture has a direct replacement" 1 (List.length initial_links);
  let raw = In_channel.with_open_bin path In_channel.input_all in
  (match Store.compact_log store ~at:206. with Ok _ -> () | Error _ -> fail "compact_log failed");
  let cold = project time in
  check bool "same ordered events and source coordinates before and after molt" true
    (before.events = cold.events && before.ticks = cold.ticks && cold.gaps = []);
  let checkpoint = In_channel.with_open_bin path In_channel.input_all in
  Out_channel.with_open_bin path (fun oc -> output_string oc raw);
  check bool "publish-before-rewrite overlap counts each sequence once" true ((project time).events = before.events);
  Out_channel.with_open_bin path (fun oc -> output_string oc checkpoint);
  let last = match Log_store.read_tail path with
    | Ok (Written { last; _ }) -> last
    | Ok Nothing_written | Error _ -> fail "missing fixture tail" in
  check bool "stale checkpoint cannot replace a longer live log" true
    (match Log_store.rewrite_compacted ~path ~at_end:0 last with
     | Error (End_moved _) -> true
     | Ok _ | Error (Directory_unavailable _ | Write_failed _) -> false);
  check string "newer log bytes survive the refused rewrite" checkpoint (In_channel.with_open_bin path In_channel.input_all);
  let archive_path = Log_store.archive_path_of_log_path path in
  let c = List.find (fun (c : Masc.Librarian_memory_change.t) -> c.at = 205.) (read ()).changes in
  let old, removal = List.hd c.removed in
  let c2 = { c with seq = c.seq + 1; revision = c.revision + 1; at = c.at } in
  let repeated = { (read ()) with unsequenced = []; changes = [c; c2] } in
  let repeat = Diff.project ~range:time ~current ~revision repeated in
  check bool "two committed occurrences may have the same IDs and the same time" true
    (List.map (fun (seq, _, _, _, _, _) -> seq) (links repeat) = [ Some c.seq; Some c2.seq ]);
  let unknown = id_of_claim "unretained successor" in
  let missing = { c with added = []; removed = [old, Superseded_by unknown] } in
  let incomplete = Diff.project ~range:time ~current ~revision { repeated with changes = [missing] } in
  check bool "missing successor body retains the proved direct ID" true
    (List.exists (function _, Diff.Successor_unavailable { successor_id; _ } -> successor_id = unknown
                 | _, (Diff.Removed _ | Diff.Added _ | Diff.Updated _) -> false) incomplete.events);
  (* The historical sidecar has no source or revision. Its direct target ID
     and time are attested even when the later log only contains a checkpoint. *)
  Out_channel.with_open_bin archive_path (fun oc ->
    output_string oc (Yojson.Safe.to_string (`Assoc [ "fact", Types.fact_to_json old
      ; "removal", Masc.Librarian_log_codec.removal_to_json removal; "at", `Float c.at; "line_at", `Int c.line_at ]) ^ "\n"));
  let historical = project time in
  check bool "legacy link has event time and current successor with unknown revision" true
    (links historical = [None, None, 205., Types.memory_id old, id_of_claim new_owner, Diff.Current_snapshot]);
  check bool "missing original sequences visible" true (historical.gaps <> []);
  check bool "revision filter never guesses a revision for an old timestamp" true
    ((project (Diff.Revisions (c.revision, c.revision))).events = []);
  Out_channel.with_open_gen [ Open_wronly; Open_append; Open_binary ] 0o600 archive_path
    (fun oc -> output_string oc "damaged\n");
  check int "partial archive reports unreadable rows" 1 (read ()).unreadable;
  Out_channel.with_open_gen [ Open_wronly; Open_append; Open_binary ] 0o600 archive_path
    (fun oc -> output_string oc "{");
  check int "an incomplete cold record counts separately" 2 (read ()).unreadable;
  let checkpoint_at at =
    let store = match Store.boot ~memory_dir:place.memory_dir ~turns_dir:place.turns_dir ~keeper_id ~at with
      | Ok store -> store | Error _ -> fail "could not reopen the valid checkpoint tail" in
    match Store.compact_log store ~at with
    | Ok _ -> () | Error _ -> fail "unreadable historical data blocked the next checkpoint" in
  checkpoint_at 207.;
  check int "a successful checkpoint keeps both damaged cold records visible" 2 (read ()).unreadable;
  let variant = { c with revision = c.revision + 1 } in
  Out_channel.with_open_gen [ Open_wronly; Open_append; Open_binary ] 0o600 archive_path
    (fun oc -> List.iter (fun change ->
      output_string oc (Yojson.Safe.to_string (Masc.Librarian_memory_change.to_json change) ^ "\n")) [c; variant]);
  let undecodable = "\255\000broken row" in
  let damaged_live = undecodable ^ "\n" ^ In_channel.with_open_bin path In_channel.input_all in
  Out_channel.with_open_bin path (fun oc -> output_string oc damaged_live);
  checkpoint_at 208.;
  let renewed = In_channel.with_open_bin path In_channel.input_all in
  check int "live history returns to one checkpoint" 1 (List.length (String.split_on_char '\n' renewed) - 1);
  check int "two cold errors, one historical live error and one conflicting sequence survive" 4 (read ()).unreadable;
  Out_channel.with_open_bin path (fun oc -> output_string oc damaged_live);
  check int "archive publication overlapping the former damaged live file counts each issue once" 4 (read ()).unreadable;
  Out_channel.with_open_bin path (fun oc -> output_string oc renewed);
  checkpoint_at 209.;
  check int "another checkpoint keeps the same unresolved count" 4 (read ()).unreadable;
  check bool "neither conflicting generation becomes a fact" true
    (List.for_all (fun (change : Masc.Librarian_memory_change.t) -> change.seq <> c.seq) (read ()).changes);
  let rows = In_channel.with_open_bin archive_path In_channel.input_lines |> List.map Yojson.Safe.from_string in
  let opaque = List.filter_map (function
    | `List [`String "librarian.unreadable.v1"; `String source; `Int _; `Int _; `String bytes] ->
      Some (source, Base64.decode_exn bytes)
    | _ -> None) rows |> List.sort compare in
  check (list (pair string string)) "raw bytes and the cold fragment are recoverable"
    ["archive", "damaged"; "archive_fragment", "{"; "live", undecodable] opaque;
  let versions = List.filter_map (fun row ->
    match Masc.Librarian_memory_change.of_json row with
    | Ok change when change.seq = c.seq -> Some change.revision | Ok _ | Error _ -> None) rows in
  check (list int) "both original sequence versions remain recoverable"
    [c.revision; variant.revision] (List.sort Int.compare versions)
;;

let test_compact_log_preserves_promotions_across_reboot_and_archive_read () =
  let place = started_place () in
  let state = after_two_removals place in
  let store =
    match state.state with
    | Idle { store; _ } -> store
    | Asking _ | Resting _ | Refused_at_bottom _ | Stopped _ ->
      fail "expected idle store"
  in
  let held_fact = List.hd (Store.memory store).facts in
  let promo : Masc.Librarian_lifecycle.world_promotion =
    { source_fact_ids = [ Types.memory_id held_fact ]
    ; claim = "shared platform invariant"
    ; category = Types.Validated_approach
    ; facets = [ "platform" ]
    ; scope = "workspace"
    }
  in
  let qid =
    match
      Masc.Librarian_question_id.of_halves
        ~front:(String.make 32 '1')
        ~back:(String.make 32 '2')
    with
    | Some q -> q
    | None -> fail "bad qid"
  in
  let room_q : Masc.Librarian_room_result.question =
    { id = qid
    ; memory = [ "m1", Types.memory_id held_fact ]
    ; basis = Masc.Librarian_log.snapshot_after (Store.tail store)
    ; trace = "molt-promo-test"
    }
  in
  let plan : Masc.Librarian_plan.t =
    { facts = (Store.memory store).facts
    ; effects = { Effects.empty with promotions = [ promo ] }
    ; working_state = Masc.Librarian_plan.Kept
    }
  in
  let store_with_promo =
    match
      Store.commit_molt store ~at:210.0 ~question:room_q ~slot:"slot-1"
        ~trigger:(Masc.Librarian_lifecycle.Compaction_epoch_advanced { epoch_id = 1 }) plan
    with
    | Store.Committed { store; _ } -> store
    | Store.Committed_without_snapshot _ | Store.Stopped _ | Store.Not_a_snapshot _ ->
      fail "expected committed molt with promotion"
  in
  let _compacted_store, compacted_lines =
    match Store.compact_log store_with_promo ~at:211.0 with
    | Ok res -> res
    | Error _ -> fail "compact_log failed"
  in
  check bool "compacted multiple lines" true (compacted_lines >= 5);
  (* Simulate crash right after compact_log and reboot via Store.boot:
     unannounced Promote_to_world MUST still be recovered from Checkpoint tail! *)
  let rebooted =
    match
      Store.boot ~memory_dir:place.memory_dir ~turns_dir:place.turns_dir ~keeper_id ~at:212.0
    with
    | Ok s -> s
    | Error _ -> fail "reboot after compact_log failed"
  in
  (match Store.last_promotions rebooted with
   | Some (_seq, [ recovered ]) ->
     check string "recovered promotion claim after compact_log reboot"
       "shared platform invariant" recovered.claim
   | Some (_, promos) ->
     failf "expected 1 recovered promotion, got %d" (List.length promos)
   | None -> fail "compact_log dropped unannounced Promote_to_world across reboot!");
  (* Cold archive + live-first Archive.read still returns all 3 removed facts. *)
  check (pair (list string) int) "archive read preserves all removals after compact_log"
    (all_three, 0)
    (archive_text place ~current:(Store.memory rebooted).facts)
;;

let test_eio_concurrent_compact_log_and_archive_read () =
  let place = started_place () in
  let state = after_two_removals place in
  let store =
    match state.state with
    | Idle { store; _ } -> store
    | Asking _ | Resting _ | Refused_at_bottom _ | Stopped _ ->
      fail "expected idle store"
  in
  let current = (Store.memory store).facts in
  (* Single-domain Eio concurrency test: Store.compact_log suspends fibers inside
     Fs_compat.save_file_atomic_strict (Systhread_host.run) while holding
     Librarian_archive.with_path_lock; a concurrent Librarian_archive.read on the
     same domain must wait cooperatively via Cross_context_mutex (never self-deadlock). *)
  Eio_main.run (fun _env ->
    let compact_result = ref None in
    let read_results = ref [] in
    Eio.Fiber.both
      (fun () ->
         compact_result := Some (Store.compact_log store ~at:250.0))
      (fun () ->
         for _ = 1 to 10 do
           let res = Archive.read (log_path place) ~current in
           read_results := res :: !read_results;
           Eio.Fiber.yield ()
         done);
    (match !compact_result with
     | Some (Ok (_compacted_store, count)) ->
       check bool "concurrent Eio compact_log succeeded" true (count >= 4)
     | Some (Error _) -> fail "concurrent Eio compact_log failed"
     | None -> fail "concurrent Eio compact_log did not finish");
    List.iter
      (fun res ->
         match res with
         | Error _ -> fail "concurrent Eio archive read failed"
         | Ok { Archive.left; unreadable } ->
           check int "zero unreadable lines during concurrent compaction" 0 unreadable;
           check int "all 3 removals visible during concurrent compaction" 3 (List.length left))
      !read_results)
;;

let () =
  run "librarian_archive"
    [ ( "left"
      , [ test_case "ordered memory changes before and after molt" `Quick test_memory_diff_through_compaction
        ; test_case "what left and why" `Quick test_what_left_and_why
        ; test_case "a fact added again" `Quick test_a_fact_added_again_is_not_left
        ; test_case "a fact the snapshot holds" `Quick test_a_fact_the_snapshot_holds_is_not_left
        ; test_case "lines that do not decode" `Quick test_lines_that_do_not_decode_are_counted
        ; test_case "compact_log preserves promotions across reboot & live-first archive read" `Quick
            test_compact_log_preserves_promotions_across_reboot_and_archive_read
        ; test_case "Eio concurrent compact_log and archive read never deadlocks" `Quick
            test_eio_concurrent_compact_log_and_archive_read
        ] )
    ]
;;
