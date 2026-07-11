(** test_board_ttl.ml - Board TTL, permanent post, and post_kind classification tests *)

open Masc.Board

(* #9903 test isolation: [create_post] now persists through
   [Env_config_core.base_path ()], which raises [Config_error] in test
   executables when the resolved path falls under HOME (PR #12584 moved
   persistence outside the board lock and onto the live ledger path).
   Pin [MASC_BASE_PATH] to a per-run tmp dir so the persist guard is
   satisfied and ledger writes stay isolated from production. *)
let () =
  let dir =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-test-board-ttl-%06x" (Random.bits ()))
  in
  Unix.putenv "MASC_BASE_PATH" dir

let () = Mirage_crypto_rng_unix.use_default ()

let with_eio f () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  f ()

let test_default_ttl () =
  Alcotest.(check int) "default_ttl_hours is 0" 0 Limits.default_ttl_hours

(* Issue #8392: schema enums for [visibility] must stay in sync with the
   Variant SSOT. The witness function uses an exhaustive [match]: adding
   a 5th constructor to [visibility] forces [visibility_to_string] to
   fail compilation, and the count assertion below catches list/Variant
   drift in [all_visibilities]. *)
let test_visibility_witness_in_enum () =
  let module C = Masc.Board_core_classify in
  let witness s =
    let actual = C.visibility_to_string s in
    if not (List.mem actual C.valid_visibility_strings) then
      Alcotest.failf "visibility_to_string %S not in valid_visibility_strings" actual
  in
  witness Public;
  witness Unlisted;
  witness Internal;
  witness Direct;
  Alcotest.(check int) "count" 4
    (List.length C.valid_visibility_strings)

let test_visibility_strings_complete () =
  let strs = Masc.Board_core_classify.valid_visibility_strings in
  List.iter (fun expected ->
    Alcotest.(check bool) (Printf.sprintf "%s present" expected) true
      (List.mem expected strs)
  ) ["public"; "unlisted"; "internal"; "direct"]

(* Issue #8449 PR A: Board_dispatch.sort_order schema enum SSOT.
   Witness covers all 5 variants; adding a 6th constructor will fail
   compilation in [sort_order_to_string]. *)
let test_sort_order_witness_in_enum () =
  let module D = Masc.Board_dispatch in
  let witness s =
    let actual = D.sort_order_to_string s in
    if not (List.mem actual D.valid_sort_order_strings) then
      Alcotest.failf "sort_order_to_string %S not in valid_sort_order_strings" actual
  in
  witness D.Hot;
  witness D.Best;
  witness D.Recent;
  witness D.Updated;
  witness D.Discussed;
  Alcotest.(check int) "count" 5
    (List.length D.valid_sort_order_strings)

let test_sort_order_legacy_aliases_rejected () =
  let module D = Masc.Board_dispatch in
  let rejected label raw =
    Alcotest.(check (option string)) label None
      (D.sort_order_of_string_opt raw |> Option.map D.sort_order_to_string)
  in
  rejected "new rejected" "new";
  rejected "active rejected" "active";
  rejected "comments rejected" "comments";
  (* board-quality-wilson (#58): "trending" is a retired sort name, not an
     alias for "best" — a silent alias would hide the semantic change
     (net-vote+decay vs. confidence-weighted ratio) from any caller still
     passing the old string. *)
  rejected "trending rejected (retired, not an alias for best)" "trending";
  rejected "garbage rejected" "definitely-not-an-order"

let test_permanent_post () =
  let store = create_store () in
  match
    create_post store ~author:"test-agent" ~content:"Permanent post"
      ~post_kind:Human_post ()
  with
  | Ok post ->
      Alcotest.(check (float 0.0)) "expires_at = 0.0" 0.0 post.expires_at
  | Error e -> Alcotest.fail (show_board_error e)

let test_expiring_post () =
  let store = create_store () in
  match
    create_post store ~author:"test-agent" ~content:"Expiring post"
      ~post_kind:Human_post ~ttl_hours:24 ()
  with
  | Ok post ->
      Alcotest.(check bool) "expires_at > 0.0" true (post.expires_at > 0.0)
  | Error e -> Alcotest.fail (show_board_error e)

let test_sweeper_skips_permanent () =
  let store = create_store () in
  (match
     create_post store ~author:"test-agent" ~content:"Permanent"
       ~post_kind:Human_post ()
   with
   | Ok _ -> ()
   | Error e -> Alcotest.fail (show_board_error e));
  let (removed_posts, _) = sweep store in
  Alcotest.(check int) "sweeper removed 0 permanent posts" 0 removed_posts

let test_sweep_reclaims_orphaned_reactions_and_votes () =
  let store = create_store () in
  let post_id =
    match
      create_post store ~author:"test-agent"
        ~content:"Post with a reaction and a vote" ~post_kind:Human_post
        ~ttl_hours:1 ()
    with
    | Ok post -> Post_id.to_string post.id
    | Error e -> Alcotest.fail (show_board_error e)
  in
  (match
     toggle_reaction store ~target_type:Reaction_post ~target_id:post_id
       ~user_id:"reactor-agent" ~emoji:"👍"
   with
   | Ok _ -> ()
   | Error e -> Alcotest.fail (show_board_error e));
  (match vote store ~voter:"voter-agent" ~post_id ~direction:Up with
   | Ok _ -> ()
   | Error e -> Alcotest.fail (show_board_error e));
  Alcotest.(check bool) "reaction present before sweep" true
    (Hashtbl.length store.reactions > 0);
  Alcotest.(check bool) "vote present before sweep" true
    (Hashtbl.length store.vote_log > 0);
  (* Simulate the post already gone — expired and swept in an earlier pass, or
     reloaded as an orphan on boot.  A per-removal hook could never revisit its
     reactions/votes because the post is no longer in [store.posts]; the
     existence-based reclaim in [sweep] must still collect them. *)
  Hashtbl.remove store.posts post_id;
  let _ = sweep store in
  Alcotest.(check int) "orphaned reactions reclaimed" 0
    (Hashtbl.length store.reactions);
  Alcotest.(check int) "orphaned votes reclaimed" 0
    (Hashtbl.length store.vote_log)

let schedule_reset_timestamp_for_test = 0.0

let reset_sweep_schedule_for_test =
  Masc_board_handlers.Board_core_persist.reset_sweep_schedule_for_test

let sweep_schedule_timestamps_for_test =
  Masc_board_handlers.Board_core_persist.sweep_schedule_timestamps_for_test

let maybe_sweep_for_test = Masc_board_handlers.Board_core_persist.maybe_sweep

let flusher_inbox_capacity_for_test =
  Masc_board_handlers.Board_core_persist.flusher_inbox_capacity

let flusher_schedule_dropped_count_for_test =
  Masc_board_handlers.Board_core_persist.flusher_schedule_dropped_count

let drain_flusher_inbox store =
  let rec loop acc =
    match Eio.Stream.take_nonblocking store.flusher_inbox with
    | None -> List.rev acc
    | Some msg -> loop (msg :: acc)
  in
  loop []

let check_one_sweep_and_flush label messages =
  let sweep_count, flush_count =
    List.fold_left
      (fun (sweeps, flushes) msg ->
         match msg with
         | Sweep -> (sweeps + 1, flushes)
         | Flush -> (sweeps, flushes + 1))
      (0, 0)
      messages
  in
  Alcotest.(check int) (label ^ " sweep count") 1 sweep_count;
  Alcotest.(check int) (label ^ " flush count") 1 flush_count

let test_maybe_sweep_updates_schedule_once () =
  let store = create_store () in
  reset_sweep_schedule_for_test store;
  maybe_sweep_for_test store;
  let first_sweep, first_flush = sweep_schedule_timestamps_for_test store in
  Alcotest.(check bool) "sweep timestamp updated" true (first_sweep > 0.0);
  Alcotest.(check bool) "flush timestamp updated" true (first_flush > 0.0);
  maybe_sweep_for_test store;
  let second_sweep, second_flush = sweep_schedule_timestamps_for_test store in
  Alcotest.(check (float 0.0)) "sweep timestamp unchanged" first_sweep second_sweep;
  Alcotest.(check (float 0.0)) "flush timestamp unchanged" first_flush second_flush;
  check_one_sweep_and_flush "sequential" (drain_flusher_inbox store)

let test_maybe_sweep_concurrent_schedules_once () =
  let store = create_store () in
  reset_sweep_schedule_for_test store;
  let callers = List.init 32 Fun.id in
  let _ =
    Eio.Fiber.List.map
      ~max_fibers:32
      (fun _ -> maybe_sweep_for_test store)
      callers
  in
  check_one_sweep_and_flush "concurrent" (drain_flusher_inbox store)

let test_maybe_sweep_full_inbox_rolls_back_schedule () =
  let store = create_store () in
  reset_sweep_schedule_for_test store;
  for _ = 1 to flusher_inbox_capacity_for_test do
    Eio.Stream.add store.flusher_inbox Flush
  done;
  let dropped_before = flusher_schedule_dropped_count_for_test () in
  maybe_sweep_for_test store;
  let dropped_after = flusher_schedule_dropped_count_for_test () in
  let sweep_ts, flush_ts = sweep_schedule_timestamps_for_test store in
  Alcotest.(check int) "full inbox dropped scheduled messages" 2
    (dropped_after - dropped_before);
  Alcotest.(check (float 0.0))
    "sweep timestamp rolled back"
    schedule_reset_timestamp_for_test
    sweep_ts;
  Alcotest.(check (float 0.0))
    "flush timestamp rolled back"
    schedule_reset_timestamp_for_test
    flush_ts;
  Alcotest.(check int)
    "full inbox length unchanged"
    flusher_inbox_capacity_for_test
    (Eio.Stream.length store.flusher_inbox)

let test_post_kind_direct_default () =
  let store = create_store () in
  match
    create_post store ~author:"test-agent" ~content:"Human post"
      ~post_kind:Human_post ()
  with
  | Ok post ->
      let json = post_to_yojson post in
      let kind = Yojson.Safe.Util.(json |> member "post_kind" |> to_string) in
      let reason =
        Yojson.Safe.Util.(json |> member "classification_reason" |> to_string)
      in
      Alcotest.(check string) "kind is direct" "direct" kind;
      Alcotest.(check string) "reason"
        "Direct board post without automation provenance." reason
  | Error e -> Alcotest.fail (show_board_error e)

let test_post_kind_automation_contract () =
  let store = create_store () in
  match
    create_post store ~author:"dashboard-harness-bot" ~content:"Harness post"
      ~visibility:Internal ~ttl_hours:1 ~hearth:"dashboard-harness"
      ~post_kind:Automation_post ()
  with
  | Ok post ->
      let json = post_to_yojson post in
      let kind = Yojson.Safe.Util.(json |> member "post_kind" |> to_string) in
      Alcotest.(check string) "kind is automation" "automation" kind
  | Error e -> Alcotest.fail (show_board_error e)

let test_post_kind_system_contract () =
  let store = create_store () in
  match
    create_post store ~author:"operator" ~content:"System post"
      ~post_kind:System_post ()
  with
  | Ok post ->
      let json = post_to_yojson post in
      let kind = Yojson.Safe.Util.(json |> member "post_kind" |> to_string) in
      Alcotest.(check string) "kind is system" "system" kind
  | Error e -> Alcotest.fail (show_board_error e)

let test_post_kind_prefers_explicit_judgment () =
  let store = create_store () in
  let summary =
    "LLM judged this as automation because it summarizes a completed keeper \
     background run."
  in
  let meta =
    `Assoc
      [
        ("source", `String "keeper_board_post");
        ( "judgment",
          `Assoc
            [
              ("summary", `String summary);
              ("confidence", `Float 0.82);
            ] );
      ]
  in
  match
    create_post store ~author:"dm-keeper" ~content:"Keeper board post"
      ~post_kind:Automation_post ~meta_json:meta ()
  with
  | Ok post ->
      let json = post_to_yojson post in
      let reason =
        Yojson.Safe.Util.(json |> member "classification_reason" |> to_string)
      in
      Alcotest.(check string) "judgment summary overrides fallback" summary
        reason
  | Error e -> Alcotest.fail (show_board_error e)

let test_post_kind_keeper_provenance_upgrade () =
  let store = create_store () in
  let meta = `Assoc [ ("source", `String "keeper_board_post") ] in
  match
    create_post store ~author:"dm-keeper" ~content:"Keeper board post"
      ~post_kind:Automation_post ~meta_json:meta ()
  with
  | Ok post ->
      Alcotest.(check bool) "classified as automation" true
        (classify_post_kind post = Automation_post);
      let json = post_to_yojson post in
      let kind = Yojson.Safe.Util.(json |> member "post_kind" |> to_string) in
      let reason =
        Yojson.Safe.Util.(json |> member "classification_reason" |> to_string)
      in
      Alcotest.(check string) "kind is automation" "automation" kind;
      Alcotest.(check string) "provenance reason"
        "Automation classification based on source=keeper_board_post, \
         author=dm-keeper, and the automation post_kind contract."
        reason
  | Error e -> Alcotest.fail (show_board_error e)

let () =
  Alcotest.run "Board_TTL"
    [
      ( "ttl",
        [
          Alcotest.test_case "default TTL is 0" `Quick test_default_ttl;
          Alcotest.test_case "permanent post" `Quick
            (with_eio test_permanent_post);
          Alcotest.test_case "expiring post" `Quick
            (with_eio test_expiring_post);
          Alcotest.test_case "sweeper skips permanent" `Quick
            (with_eio test_sweeper_skips_permanent);
          Alcotest.test_case "sweep reclaims orphaned reactions and votes"
            `Quick
            (with_eio test_sweep_reclaims_orphaned_reactions_and_votes);
          Alcotest.test_case "maybe_sweep schedules once" `Quick
            (with_eio test_maybe_sweep_updates_schedule_once);
          Alcotest.test_case "maybe_sweep concurrent schedules once" `Quick
            (with_eio test_maybe_sweep_concurrent_schedules_once);
          Alcotest.test_case "maybe_sweep full inbox rolls back schedule" `Quick
            (with_eio test_maybe_sweep_full_inbox_rolls_back_schedule);
        ] );
      ( "visibility_ssot",
        [
          Alcotest.test_case "witness covers all 4 variants" `Quick
            test_visibility_witness_in_enum;
          Alcotest.test_case "all 4 strings present" `Quick
            test_visibility_strings_complete;
        ] );
      ( "sort_order_ssot",
        [
          Alcotest.test_case "witness covers all 5 variants" `Quick
            test_sort_order_witness_in_enum;
          Alcotest.test_case "legacy aliases rejected" `Quick
            test_sort_order_legacy_aliases_rejected;
        ] );
      ( "post_kind",
        [
          Alcotest.test_case "direct default" `Quick
            (with_eio test_post_kind_direct_default);
          Alcotest.test_case "automation contract" `Quick
            (with_eio test_post_kind_automation_contract);
          Alcotest.test_case "system contract" `Quick
            (with_eio test_post_kind_system_contract);
          Alcotest.test_case "prefers explicit judgment" `Quick
            (with_eio test_post_kind_prefers_explicit_judgment);
          Alcotest.test_case "keeper provenance upgrade" `Quick
            (with_eio test_post_kind_keeper_provenance_upgrade);
        ] );
    ]
