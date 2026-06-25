(** Unit tests for Board_moderation — moderation queue and audit trail.

    Covers:
    - Round-trip conversions for flag_reason, action_kind, target_kind
    - flag: happy path, duplicate rejection
    - get_queue: filtering by resolved status
    - resolve_entry: happy path and not-found error
    - record_action: happy path, note capping, auto-resolve of queue entry
    - get_audit_trail: actor/target filters and limit cap
    - target_summary: report count and moderation status projection
    - JSON projection shapes for queue_entry_to_json and audit_entry_to_json
*)

open Alcotest
open Masc
module BM = Board_moderation

external unsetenv : string -> unit = "masc_test_unsetenv"

(* Initialise Mirage crypto RNG — required for Random_id.prefixed *)
let () = Mirage_crypto_rng_unix.use_default ()
let () = Random.self_init ()

(* ── Helpers ──────────────────────────────────────────────────────── *)

let reset () = BM.reset_for_test ()

let fresh_test_base_path () =
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-test-board-moderation-%06x" (Random.bits ()))
  in
  Unix.putenv "MASC_BASE_PATH" dir;
  dir

let with_env key value f =
  let prev = Sys.getenv_opt key in
  Unix.putenv key value;
  Fun.protect
    ~finally:(fun () ->
      match prev with
      | Some v -> Unix.putenv key v
      | None -> unsetenv key)
    f

let with_flag_rate_limit value f =
  with_env "MASC_BOARD_MODERATION_FLAG_RATE_LIMIT_SEC" value f

let read_file path =
  let ic = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () -> In_channel.input_all ic)

let rec source_root_from dir hops =
  let anchor =
    Filename.concat dir "lib/server/server_dashboard_http_delete_actions.ml"
  in
  if Sys.file_exists anchor then dir
  else if hops >= 8 then fail "could not locate repository source root"
  else
    let parent = Filename.dirname dir in
    if String.equal parent dir
    then fail "could not locate repository source root"
    else source_root_from parent (hops + 1)

let source_root () =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root -> root
  | None -> source_root_from (Sys.getcwd ()) 0

let read_source_file rel = read_file (Filename.concat (source_root ()) rel)

let contains_substring s needle =
  let s_len = String.length s in
  let n_len = String.length needle in
  let rec loop i =
    if n_len = 0
    then true
    else if i + n_len > s_len
    then false
    else if String.sub s i n_len = needle
    then true
    else loop (i + 1)
  in
  loop 0

let find_substring_from source needle start =
  let source_len = String.length source in
  let needle_len = String.length needle in
  let rec loop i =
    if needle_len = 0
    then Some i
    else if i + needle_len > source_len
    then None
    else if String.sub source i needle_len = needle
    then Some i
    else loop (i + 1)
  in
  loop start

let find_substring source needle = find_substring_from source needle 0

let slice_between source ~start_marker ~end_marker =
  match find_substring source start_marker with
  | None -> fail ("missing start marker: " ^ start_marker)
  | Some start ->
    (match find_substring_from source end_marker start with
     | None -> fail ("missing end marker: " ^ end_marker)
     | Some finish -> String.sub source start (finish - start))

let slice_from source ~start_marker =
  match find_substring source start_marker with
  | None -> fail ("missing start marker: " ^ start_marker)
  | Some start -> String.sub source start (String.length source - start)

let run_eio f =
  Eio_main.run (fun env ->
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    ignore (fresh_test_base_path ());
    Board.reset_global_for_test ();
    Board_dispatch.reset_for_test ();
    Board_dispatch.init_jsonl ();
    f ())

let create_public_post_id content =
  match
    Board_dispatch.create_post
      ~author:"moderation-test"
      ~content
      ~post_kind:Board.Human_post
      ~visibility:Board.Public
      ()
  with
  | Ok post -> Board.Post_id.to_string post.id
  | Error e -> fail (Board.show_board_error e)

let test_with_env_restores_unset () =
  let key = "MASC_BOARD_MODERATION_TEST_UNSET" in
  unsetenv key;
  check (option string) "starts unset" None (Sys.getenv_opt key);
  with_env key "set-for-test" (fun () ->
    check (option string) "set inside scope" (Some "set-for-test")
      (Sys.getenv_opt key));
  check (option string) "restored unset" None (Sys.getenv_opt key)

(* ── flag_reason roundtrips ───────────────────────────────────────── *)

let test_flag_reason_spam () =
  reset ();
  let r = BM.Spam in
  check string "spam string" "spam" (BM.flag_reason_to_string r);
  check (option (of_pp BM.pp_flag_reason)) "spam parse"
    (Some BM.Spam) (BM.flag_reason_of_string "spam")

let test_flag_reason_harassment () =
  reset ();
  check (option (of_pp BM.pp_flag_reason)) "harassment parse"
    (Some BM.Harassment) (BM.flag_reason_of_string "harassment");
  check string "harassment string" "harassment"
    (BM.flag_reason_to_string BM.Harassment)

let test_flag_reason_off_topic () =
  reset ();
  check string "off_topic string" "off_topic"
    (BM.flag_reason_to_string BM.Off_topic);
  check (option (of_pp BM.pp_flag_reason)) "off_topic parse"
    (Some BM.Off_topic) (BM.flag_reason_of_string "off_topic")

let test_flag_reason_policy () =
  reset ();
  let r = BM.Policy_violation "no-hate-speech" in
  let s = BM.flag_reason_to_string r in
  check string "policy string prefix" "policy:no-hate-speech" s;
  check (option (of_pp BM.pp_flag_reason)) "policy roundtrip"
    (Some r) (BM.flag_reason_of_string s)

let test_flag_reason_unknown () =
  reset ();
  check (option (of_pp BM.pp_flag_reason)) "unknown -> None"
    None (BM.flag_reason_of_string "nonsense")

(* ── action_kind roundtrips ──────────────────────────────────────── *)

let test_action_kind_roundtrips () =
  reset ();
  let cases = [
    (BM.Approve, "approve");
    (BM.Remove,  "remove");
    (BM.Hide,    "hide");
    (BM.Warn,    "warn");
  ] in
  List.iter
    (fun (ak, s) ->
       check string ("to_string " ^ s) s (BM.action_kind_to_string ak);
       check (option (of_pp BM.pp_action_kind)) ("of_string " ^ s)
         (Some ak) (BM.action_kind_of_string s))
    cases;
  check (option (of_pp BM.pp_action_kind)) "unknown -> None"
    None (BM.action_kind_of_string "delete")

let test_dashboard_flag_route_binds_reporter_to_authenticated_agent () =
  let source =
    read_source_file "lib/server/server_dashboard_http_delete_actions.ml"
  in
  let route_source =
    slice_between
      source
      ~start_marker:
        {|"/api/v1/dashboard/board/moderation/flag"|}
      ~end_marker:
        {|"/api/v1/dashboard/board/moderation/queue"|}
  in
  check
    bool
    "flag route captures authenticated agent_name"
    true
    (contains_substring route_source "fun _state agent_name req reqd");
  check
    bool
    "flag route ignores spoofable reporter body field"
    false
    (contains_substring route_source {|json_string_opt "reporter"|});
  check
    bool
    "flag route records reporter from authenticated agent_name"
    true
    (contains_substring route_source "let reporter = agent_name")

let test_dashboard_action_route_binds_actor_to_authenticated_agent () =
  let source =
    read_source_file "lib/server/server_dashboard_http_delete_actions.ml"
  in
  let route_source =
    slice_from
      source
      ~start_marker:
        {|"/api/v1/dashboard/board/moderation/action"|}
  in
  check
    bool
    "action route captures authenticated agent_name"
    true
    (contains_substring route_source "fun _state agent_name req reqd");
  check
    bool
    "action route ignores spoofable actor body field"
    false
    (contains_substring route_source {|json_string_opt "actor"|});
  check
    bool
    "action route records actor from authenticated agent_name"
    true
    (contains_substring route_source "let actor = agent_name")

(* ── target_kind roundtrips ──────────────────────────────────────── *)

let test_target_kind_roundtrips () =
  reset ();
  check string "post string" "post"
    (BM.target_kind_to_string BM.Target_post);
  check string "comment string" "comment"
    (BM.target_kind_to_string BM.Target_comment);
  check (option (of_pp BM.pp_target_kind)) "post parse"
    (Some BM.Target_post) (BM.target_kind_of_string "post");
  check (option (of_pp BM.pp_target_kind)) "comment parse"
    (Some BM.Target_comment) (BM.target_kind_of_string "comment");
  check (option (of_pp BM.pp_target_kind)) "unknown -> None"
    None (BM.target_kind_of_string "thread")

(* ── flag: happy path ────────────────────────────────────────────── *)

let test_flag_happy_path () =
  reset ();
  (match BM.flag ~target_kind:BM.Target_post ~target_id:"p1"
           ~reporter:"agent-a" ~reason:BM.Spam with
   | Error msg -> fail ("unexpected error: " ^ msg)
   | Ok entry ->
       check string "entry_id prefix" "mq-"
         (String.sub entry.BM.entry_id 0 3);
       check string "target_id" "p1" entry.BM.target_id;
       check string "reporter" "agent-a" entry.BM.reporter;
       check bool "resolved=false" false entry.BM.resolved)

let test_flag_duplicate_rejected () =
  reset ();
  let flag () =
    BM.flag ~target_kind:BM.Target_post ~target_id:"p2"
      ~reporter:"agent-b" ~reason:BM.Harassment
  in
  (match flag () with Ok _ -> () | Error m -> fail ("first flag failed: " ^ m));
  (match flag () with
   | Error _ -> ()  (* Expected *)
   | Ok _ -> fail "duplicate flag should have been rejected")

let test_flag_different_targets () =
  reset ();
  with_flag_rate_limit "0" (fun () ->
    let r1 = BM.flag ~target_kind:BM.Target_post ~target_id:"p3"
               ~reporter:"agent-c" ~reason:BM.Spam in
    let r2 = BM.flag ~target_kind:BM.Target_comment ~target_id:"c1"
               ~reporter:"agent-c" ~reason:BM.Off_topic in
    match r1, r2 with
    | Ok e1, Ok e2 ->
        check bool "different ids" true (e1.BM.entry_id <> e2.BM.entry_id)
    | _ -> fail "both flags should succeed")

let test_flag_rate_limited_same_reporter () =
  reset ();
  with_flag_rate_limit "60" (fun () ->
    (match BM.flag ~target_kind:BM.Target_post ~target_id:"rl1"
             ~reporter:"agent-rl" ~reason:BM.Spam with
     | Ok _ -> ()
     | Error m -> fail ("first flag failed: " ^ m));
    match BM.flag ~target_kind:BM.Target_comment ~target_id:"rl2"
            ~reporter:"agent-rl" ~reason:BM.Off_topic with
    | Error m ->
        check bool "rate-limit message" true
          (String.starts_with
             ~prefix:"reporter agent-rl is rate limited" m)
    | Ok _ -> fail "second flag by same reporter should be rate limited")

let test_flag_rate_limit_allows_different_reporters () =
  reset ();
  with_flag_rate_limit "60" (fun () ->
    let r1 = BM.flag ~target_kind:BM.Target_post ~target_id:"rl3"
               ~reporter:"agent-rl-a" ~reason:BM.Spam in
    let r2 = BM.flag ~target_kind:BM.Target_comment ~target_id:"rl4"
               ~reporter:"agent-rl-b" ~reason:BM.Off_topic in
    match r1, r2 with
    | Ok _, Ok _ -> ()
    | _ -> fail "different reporters should not rate-limit each other")

let test_flag_rate_limit_non_finite_falls_back () =
  let check_non_finite value target_a target_b =
    reset ();
    with_flag_rate_limit value (fun () ->
      (match BM.flag ~target_kind:BM.Target_post ~target_id:target_a
               ~reporter:"agent-nonfinite" ~reason:BM.Spam with
       | Ok _ -> ()
       | Error m -> fail ("first flag failed: " ^ m));
      match BM.flag ~target_kind:BM.Target_comment ~target_id:target_b
              ~reporter:"agent-nonfinite" ~reason:BM.Off_topic with
      | Error m ->
          check bool ("fallback rate-limit " ^ value) true
            (String.starts_with
               ~prefix:"reporter agent-nonfinite is rate limited" m)
      | Ok _ -> fail ("non-finite rate limit should fall back: " ^ value))
  in
  check_non_finite "nan" "rl-nan-1" "rl-nan-2";
  check_non_finite "+inf" "rl-inf-1" "rl-inf-2"

let test_flag_rate_limit_survives_resolved_entries () =
  reset ();
  with_flag_rate_limit "60" (fun () ->
    let first_entry =
      match BM.flag ~target_kind:BM.Target_post ~target_id:"rl-resolved-1"
              ~reporter:"agent-resolved" ~reason:BM.Spam with
      | Ok entry -> entry
      | Error m -> fail ("first flag failed: " ^ m)
    in
    (match BM.resolve_entry ~entry_id:first_entry.BM.entry_id with
     | Ok () -> ()
     | Error m -> fail ("resolve failed: " ^ m));
    match BM.flag ~target_kind:BM.Target_comment ~target_id:"rl-resolved-2"
            ~reporter:"agent-resolved" ~reason:BM.Off_topic with
    | Error m ->
        check bool "resolved entry still rate-limits reporter" true
          (String.starts_with
             ~prefix:"reporter agent-resolved is rate limited" m)
    | Ok _ -> fail "resolved entries should still enforce reporter burst window")

(* ── get_queue filtering ─────────────────────────────────────────── *)

let test_get_queue_unresolved () =
  reset ();
  let _ = BM.flag ~target_kind:BM.Target_post ~target_id:"q1"
            ~reporter:"r" ~reason:BM.Spam in
  let q = BM.get_queue ~resolved:false () in
  check int "one pending entry" 1 (List.length q);
  check bool "entry not resolved" false (List.hd q).BM.resolved

let test_get_queue_all () =
  reset ();
  let _ = BM.flag ~target_kind:BM.Target_post ~target_id:"q2"
            ~reporter:"r1" ~reason:BM.Spam in
  let _ = BM.flag ~target_kind:BM.Target_comment ~target_id:"c2"
            ~reporter:"r2" ~reason:BM.Harassment in
  let q = BM.get_queue () in
  check int "two entries total" 2 (List.length q)

let test_get_queue_resolved_filter () =
  reset ();
  (match BM.flag ~target_kind:BM.Target_post ~target_id:"q3"
           ~reporter:"r" ~reason:BM.Spam with
   | Error m -> fail m
   | Ok entry ->
       let _ = BM.resolve_entry ~entry_id:entry.BM.entry_id in
       let pending = BM.get_queue ~resolved:false () in
       let resolved = BM.get_queue ~resolved:true () in
       check int "zero pending" 0 (List.length pending);
       check int "one resolved" 1 (List.length resolved))

(* ── resolve_entry ───────────────────────────────────────────────── *)

let test_resolve_entry_not_found () =
  reset ();
  (match BM.resolve_entry ~entry_id:"mq-nonexistent" with
   | Error _ -> ()
   | Ok () -> fail "should have returned error for unknown id")

(* ── record_action ───────────────────────────────────────────────── *)

let test_record_action_happy_path () =
  reset ();
  (match BM.record_action ~target_kind:BM.Target_post ~target_id:"p10"
           ~actor:"operator-x" ~action:BM.Approve () with
   | Error m -> fail m
   | Ok entry ->
       check string "audit_id prefix" "ma-"
         (String.sub entry.BM.audit_id 0 3);
       check string "actor" "operator-x" entry.BM.actor;
       check (of_pp BM.pp_action_kind) "action" BM.Approve entry.BM.action)

let test_record_action_note_capped () =
  reset ();
  let long_note = String.make 600 'x' in
  (match BM.record_action ~target_kind:BM.Target_post ~target_id:"p11"
           ~actor:"op" ~action:BM.Warn ~note:long_note () with
   | Error m -> fail m
   | Ok entry ->
       let note_len = Option.fold ~none:0 ~some:String.length entry.BM.note in
       check bool "note capped at 500" true (note_len <= 500))

let test_record_action_auto_resolves_queue () =
  reset ();
  (match BM.flag ~target_kind:BM.Target_post ~target_id:"p12"
           ~reporter:"r" ~reason:BM.Spam with
   | Error m -> fail ("flag failed: " ^ m)
   | Ok _ ->
       (* pending before action *)
       check int "one pending" 1 (List.length (BM.get_queue ~resolved:false ()));
       (match BM.record_action ~target_kind:BM.Target_post ~target_id:"p12"
                ~actor:"op" ~action:BM.Warn () with
        | Error m -> fail ("action failed: " ^ m)
        | Ok _ ->
            (* pending after action should be zero *)
            check int "zero pending after action" 0
              (List.length (BM.get_queue ~resolved:false ()))));
  (* resolved entry should exist *)
  check int "one resolved" 1 (List.length (BM.get_queue ~resolved:true ()))

let test_record_action_allows_target_to_be_reflagged () =
  reset ();
  with_flag_rate_limit "0" (fun () ->
    (match BM.flag ~target_kind:BM.Target_post ~target_id:"p13"
             ~reporter:"r1" ~reason:BM.Spam with
     | Ok _ -> ()
     | Error m -> fail ("flag failed: " ^ m));
    (match BM.record_action ~target_kind:BM.Target_post ~target_id:"p13"
             ~actor:"op" ~action:BM.Warn () with
     | Ok _ -> ()
     | Error m -> fail ("action failed: " ^ m));
    match BM.flag ~target_kind:BM.Target_post ~target_id:"p13"
            ~reporter:"r2" ~reason:BM.Harassment with
    | Ok _ -> ()
    | Error m -> fail ("resolved target should be flaggable again: " ^ m))

let test_record_action_remove_deletes_post () =
  reset ();
  let post_id = create_public_post_id "remove me through moderation" in
  (match BM.flag ~target_kind:BM.Target_post ~target_id:post_id
           ~reporter:"reporter" ~reason:BM.Policy_violation "remove" with
   | Ok _ -> ()
   | Error m -> fail ("flag failed: " ^ m));
  (match BM.record_action ~target_kind:BM.Target_post ~target_id:post_id
           ~actor:"operator" ~action:BM.Remove () with
   | Error m -> fail ("remove action failed: " ^ m)
   | Ok entry ->
       check (of_pp BM.pp_action_kind) "action" BM.Remove entry.BM.action);
  (match Board_dispatch.get_post ~post_id with
   | Ok _ -> fail "removed post should not be fetchable"
   | Error (Board.Post_not_found _) -> ()
   | Error e -> fail (Board.show_board_error e));
  check int "remove resolves queue" 0 (List.length (BM.get_queue ~resolved:false ()));
  let summary = BM.target_summary ~target_kind:BM.Target_post ~target_id:post_id in
  check string "status removed" "removed" summary.BM.moderation_status

let test_record_action_hide_unlists_post () =
  reset ();
  let post_id = create_public_post_id "hide me through moderation" in
  (match BM.record_action ~target_kind:BM.Target_post ~target_id:post_id
           ~actor:"operator" ~action:BM.Hide () with
   | Error m -> fail ("hide action failed: " ^ m)
   | Ok entry ->
       check (of_pp BM.pp_action_kind) "action" BM.Hide entry.BM.action);
  match Board_dispatch.get_post ~post_id with
  | Error e -> fail (Board.show_board_error e)
  | Ok post ->
      check
        string
        "visibility changed"
        "unlisted"
        (Board.visibility_to_string post.Board.visibility)

let test_record_action_remove_missing_post_rejects_without_resolving () =
  reset ();
  (match BM.flag ~target_kind:BM.Target_post ~target_id:"missing-post"
           ~reporter:"reporter" ~reason:BM.Spam with
   | Ok _ -> ()
   | Error m -> fail ("flag failed: " ^ m));
  (match BM.record_action ~target_kind:BM.Target_post ~target_id:"missing-post"
           ~actor:"operator" ~action:BM.Remove () with
   | Ok _ -> fail "missing post remove must reject"
   | Error _ -> ());
  check int "queue remains pending" 1 (List.length (BM.get_queue ~resolved:false ()));
  check int "no audit written" 0 (List.length (BM.get_audit_trail ()))

let test_record_action_rejects_blank_actor () =
  reset ();
  (match BM.record_action ~target_kind:BM.Target_post ~target_id:"p-blank-actor"
           ~actor:"  " ~action:BM.Warn () with
   | Ok _ -> fail "blank actor must reject"
   | Error _ -> ());
  check int "no audit written" 0 (List.length (BM.get_audit_trail ()))

(* ── get_audit_trail ─────────────────────────────────────────────── *)

let test_audit_trail_actor_filter () =
  reset ();
  let act a = BM.record_action ~target_kind:BM.Target_post ~target_id:"p20"
                ~actor:a ~action:BM.Approve () in
  let _ = act "alice" in
  let _ = act "bob" in
  let alice_trail = BM.get_audit_trail ~actor:"alice" () in
  let bob_trail   = BM.get_audit_trail ~actor:"bob"   () in
  check int "alice: 1 entry" 1 (List.length alice_trail);
  check int "bob: 1 entry"   1 (List.length bob_trail)

let test_audit_trail_target_filter () =
  reset ();
  let _ = BM.record_action ~target_kind:BM.Target_post ~target_id:"p30"
            ~actor:"op" ~action:BM.Warn () in
  let _ = BM.record_action ~target_kind:BM.Target_post ~target_id:"p31"
            ~actor:"op" ~action:BM.Warn () in
  let trail = BM.get_audit_trail ~target_id:"p30" () in
  check int "one entry for p30" 1 (List.length trail);
  check string "correct target" "p30" (List.hd trail).BM.target_id

let test_audit_trail_limit () =
  reset ();
  for i = 1 to 10 do
    let _ = BM.record_action ~target_kind:BM.Target_post
              ~target_id:(Printf.sprintf "pl%d" i)
              ~actor:"op" ~action:BM.Approve () in
    ()
  done;
  let limited = BM.get_audit_trail ~limit:3 () in
  check int "limit=3 returns 3" 3 (List.length limited)

(* ── target_summary ─────────────────────────────────────────────── *)

let test_target_summary_none () =
  reset ();
  let summary =
    BM.target_summary ~target_kind:BM.Target_post ~target_id:"summary-none"
  in
  check int "no reports" 0 summary.BM.report_count;
  check string "status none" "none" summary.BM.moderation_status

let test_target_summary_flagged () =
  reset ();
  (match BM.flag ~target_kind:BM.Target_comment ~target_id:"summary-flagged"
           ~reporter:"reporter" ~reason:BM.Harassment with
   | Ok _ -> ()
   | Error m -> fail m);
  let summary =
    BM.target_summary ~target_kind:BM.Target_comment ~target_id:"summary-flagged"
  in
  check int "one report" 1 summary.BM.report_count;
  check string "status flagged" "flagged" summary.BM.moderation_status

let test_target_summary_action_status () =
  reset ();
  let post_id = create_public_post_id "moderation hide summary" in
  (match BM.flag ~target_kind:BM.Target_post ~target_id:post_id
           ~reporter:"reporter" ~reason:BM.Spam with
   | Ok _ -> ()
   | Error m -> fail m);
  (match BM.record_action ~target_kind:BM.Target_post ~target_id:post_id
           ~actor:"operator" ~action:BM.Hide () with
   | Ok _ -> ()
   | Error m -> fail m);
  let summary =
    BM.target_summary ~target_kind:BM.Target_post ~target_id:post_id
  in
  check int "report retained after action" 1 summary.BM.report_count;
  check string "status hidden" "hidden" summary.BM.moderation_status

let test_target_summary_reflagged_wins_over_audit () =
  reset ();
  with_flag_rate_limit "0" (fun () ->
    (match BM.flag ~target_kind:BM.Target_post ~target_id:"summary-reflag"
             ~reporter:"reporter-a" ~reason:BM.Spam with
     | Ok _ -> ()
     | Error m -> fail m);
    (match BM.record_action ~target_kind:BM.Target_post ~target_id:"summary-reflag"
             ~actor:"operator" ~action:BM.Approve () with
     | Ok _ -> ()
     | Error m -> fail m);
    (match BM.flag ~target_kind:BM.Target_post ~target_id:"summary-reflag"
             ~reporter:"reporter-b" ~reason:BM.Harassment with
     | Ok _ -> ()
     | Error m -> fail m);
    let summary =
      BM.target_summary ~target_kind:BM.Target_post ~target_id:"summary-reflag"
    in
    check int "two reports" 2 summary.BM.report_count;
    check string "unresolved reflag wins" "flagged" summary.BM.moderation_status)

(* ── JSON projections ────────────────────────────────────────────── *)

let test_queue_entry_to_json () =
  reset ();
  (match BM.flag ~target_kind:BM.Target_post ~target_id:"jq1"
           ~reporter:"r" ~reason:BM.Spam with
   | Error m -> fail m
   | Ok entry ->
       let j = BM.queue_entry_to_json entry in
       (match j with
        | `Assoc fields ->
            check bool "has entry_id"    true (List.mem_assoc "entry_id"    fields);
            check bool "has target_kind" true (List.mem_assoc "target_kind" fields);
            check bool "has target_id"   true (List.mem_assoc "target_id"   fields);
            check bool "has reporter"    true (List.mem_assoc "reporter"    fields);
            check bool "has reason"      true (List.mem_assoc "reason"      fields);
            check bool "has flagged_at"  true (List.mem_assoc "flagged_at"  fields);
            check bool "has resolved"    true (List.mem_assoc "resolved"    fields);
            (match List.assoc_opt "resolved" fields with
             | Some (`Bool false) -> ()
             | _ -> fail "resolved should be false")
        | _ -> fail "expected Assoc"))

let test_audit_entry_to_json () =
  reset ();
  (match BM.record_action ~target_kind:BM.Target_comment ~target_id:"jc1"
           ~actor:"op" ~action:BM.Warn
           ~reason:BM.Harassment ~note:"please be kind" () with
   | Error m -> fail m
   | Ok entry ->
       let j = BM.audit_entry_to_json entry in
       (match j with
        | `Assoc fields ->
            check bool "has audit_id"    true (List.mem_assoc "audit_id"    fields);
            check bool "has actor"       true (List.mem_assoc "actor"       fields);
            check bool "has action"      true (List.mem_assoc "action"      fields);
            check bool "has reason"      true (List.mem_assoc "reason"      fields);
            check bool "has note"        true (List.mem_assoc "note"        fields);
            (match List.assoc_opt "action" fields with
             | Some (`String "warn") -> ()
             | _ -> fail "action should be warn");
            (match List.assoc_opt "reason" fields with
             | Some (`String "harassment") -> ()
             | _ -> fail "reason should be harassment")
        | _ -> fail "expected Assoc"))

let test_audit_entry_no_optional_fields_when_absent () =
  reset ();
  (match BM.record_action ~target_kind:BM.Target_post ~target_id:"jnone"
           ~actor:"op" ~action:BM.Approve () with
   | Error m -> fail m
   | Ok entry ->
       let j = BM.audit_entry_to_json entry in
       (match j with
        | `Assoc fields ->
            check bool "no reason field when None" false (List.mem_assoc "reason" fields);
            check bool "no note field when None"   false (List.mem_assoc "note"   fields)
        | _ -> fail "expected Assoc"))

(* ── Runner ──────────────────────────────────────────────────────── *)

let eio_test_case name speed f = test_case name speed (fun () -> run_eio f)

let () =
  run "Board_moderation"
    [ ( "env",
        [ eio_test_case "with_env restores unset" `Quick
            test_with_env_restores_unset ] );
      ( "flag_reason",
        [ eio_test_case "spam roundtrip"       `Quick test_flag_reason_spam;
          eio_test_case "harassment roundtrip" `Quick test_flag_reason_harassment;
          eio_test_case "off_topic roundtrip"  `Quick test_flag_reason_off_topic;
          eio_test_case "policy roundtrip"     `Quick test_flag_reason_policy;
          eio_test_case "unknown -> None"      `Quick test_flag_reason_unknown ] );
      ( "action_kind",
        [ eio_test_case "all roundtrips" `Quick test_action_kind_roundtrips ] );
      ( "source_guards",
        [ test_case "flag reporter is authenticated identity" `Quick
            test_dashboard_flag_route_binds_reporter_to_authenticated_agent;
          test_case "action actor is authenticated identity" `Quick
            test_dashboard_action_route_binds_actor_to_authenticated_agent ] );
      ( "target_kind",
        [ eio_test_case "all roundtrips" `Quick test_target_kind_roundtrips ] );
      ( "flag",
        [ eio_test_case "happy path"             `Quick test_flag_happy_path;
          eio_test_case "duplicate rejected"     `Quick test_flag_duplicate_rejected;
          eio_test_case "different targets ok"   `Quick test_flag_different_targets;
          eio_test_case "same reporter rate limited" `Quick
            test_flag_rate_limited_same_reporter;
          eio_test_case "different reporters bypass rate limit" `Quick
            test_flag_rate_limit_allows_different_reporters;
          eio_test_case "non-finite rate limit falls back" `Quick
            test_flag_rate_limit_non_finite_falls_back;
          eio_test_case "resolved entries still rate-limit reporter" `Quick
            test_flag_rate_limit_survives_resolved_entries ] );
      ( "get_queue",
        [ eio_test_case "unresolved filter"      `Quick test_get_queue_unresolved;
          eio_test_case "all entries"            `Quick test_get_queue_all;
          eio_test_case "resolved filter"        `Quick test_get_queue_resolved_filter ] );
      ( "resolve_entry",
        [ eio_test_case "not found -> error"     `Quick test_resolve_entry_not_found ] );
      ( "record_action",
        [ eio_test_case "happy path"             `Quick test_record_action_happy_path;
          eio_test_case "note capped at 500"     `Quick test_record_action_note_capped;
          eio_test_case "auto-resolves queue"    `Quick
            test_record_action_auto_resolves_queue;
          eio_test_case "allows target to be reflagged" `Quick
            test_record_action_allows_target_to_be_reflagged;
          eio_test_case "remove deletes post" `Quick
            test_record_action_remove_deletes_post;
          eio_test_case "hide unlists post" `Quick
            test_record_action_hide_unlists_post;
          eio_test_case "remove missing post rejects" `Quick
            test_record_action_remove_missing_post_rejects_without_resolving;
          eio_test_case "blank actor rejects" `Quick
            test_record_action_rejects_blank_actor ] );
      ( "get_audit_trail",
        [ eio_test_case "actor filter"           `Quick test_audit_trail_actor_filter;
          eio_test_case "target filter"          `Quick test_audit_trail_target_filter;
          eio_test_case "limit cap"              `Quick test_audit_trail_limit ] );
      ( "target_summary",
        [ eio_test_case "none"                   `Quick test_target_summary_none;
          eio_test_case "flagged"                `Quick test_target_summary_flagged;
          eio_test_case "action status"          `Quick test_target_summary_action_status;
          eio_test_case "reflag wins over audit" `Quick
            test_target_summary_reflagged_wins_over_audit ] );
      ( "json_projection",
        [ eio_test_case "queue_entry shape"      `Quick test_queue_entry_to_json;
          eio_test_case "audit_entry shape"      `Quick test_audit_entry_to_json;
          eio_test_case "audit optional absent"  `Quick
            test_audit_entry_no_optional_fields_when_absent ] ) ]
