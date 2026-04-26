(* test/test_keeper_meta_merge.ml

   Covers Keeper_meta_merge merge strategies (#9769 root fix).

   Regression scenario: a turn-failure write races with a concurrent
   heartbeat write that updates [joined_room_ids] / [last_seen_seq_by_room].
   The historical [caller_wins] merge overwrites those heartbeat fields
   on retry. The [heartbeat_fields_from_disk] merge keeps them from the
   disk snapshot, which is the correct field ownership. *)

open Masc_mcp

let fail msg = failwith msg
let assert_true msg b = if not b then fail msg

let assert_eq_int ~msg e g =
  if e <> g then fail (Printf.sprintf "%s: expected=%d got=%d" msg e g)
;;

let assert_eq_list ~msg expected got =
  if expected <> got
  then
    fail
      (Printf.sprintf
         "%s: expected=[%s] got=[%s]"
         msg
         (String.concat ";" expected)
         (String.concat ";" got))
;;

let make_meta name : Keeper_types.keeper_meta =
  let json =
    `Assoc
      [ "name", `String name
      ; "trace_id", `String ("test-trace-" ^ name)
      ; "goal", `String "test goal"
      ]
  in
  match Keeper_types.meta_of_json json with
  | Ok m -> m
  | Error e -> failwith ("meta_of_json failed: " ^ e)
;;

(* --- caller_wins preserves historical behaviour ---------------- *)

let test_caller_wins_overwrites_heartbeat_fields () =
  (* Models the pre-#9769 bug: caller never touched joined_room_ids,
     but a concurrent heartbeat updated it; caller_wins clobbers it. *)
  let base = make_meta "keeper-a" in
  let caller =
    { base with
      joined_room_ids = [ "stale-snapshot" ]
    ; last_seen_seq_by_room = [ "room-a", 1 ]
    ; meta_version = 5
    ; continuity_summary = "caller wrote this"
    }
  in
  let latest =
    { base with
      joined_room_ids = [ "live-room" ]
    ; last_seen_seq_by_room = [ "room-a", 42; "room-b", 7 ]
    ; meta_version = 6
    ; continuity_summary = ""
    }
  in
  let merged = Keeper_meta_merge.caller_wins ~latest ~caller in
  assert_eq_int ~msg:"meta_version follows disk" 6 merged.meta_version;
  assert_eq_list
    ~msg:"caller_wins clobbers joined_room_ids"
    [ "stale-snapshot" ]
    merged.joined_room_ids;
  let rooms = List.map fst merged.last_seen_seq_by_room in
  assert_eq_list ~msg:"caller_wins clobbers last_seen_seq_by_room" [ "room-a" ] rooms;
  assert_true
    "caller_wins preserves caller continuity_summary"
    (merged.continuity_summary = "caller wrote this")
;;

(* --- heartbeat_fields_from_disk keeps live heartbeat state ----- *)

let test_heartbeat_fields_from_disk () =
  let base = make_meta "keeper-b" in
  let caller =
    { base with
      joined_room_ids = [ "stale-snapshot" ]
    ; last_seen_seq_by_room = [ "room-a", 1 ]
    ; meta_version = 5
    ; continuity_summary = "caller wrote this"
    }
  in
  let latest =
    { base with
      joined_room_ids = [ "live-room" ]
    ; last_seen_seq_by_room = [ "room-a", 42; "room-b", 7 ]
    ; meta_version = 6
    ; continuity_summary = "irrelevant disk value"
    }
  in
  let merged = Keeper_meta_merge.heartbeat_fields_from_disk ~latest ~caller in
  assert_eq_int ~msg:"meta_version follows disk" 6 merged.meta_version;
  assert_eq_list ~msg:"joined_room_ids from disk" [ "live-room" ] merged.joined_room_ids;
  let rooms = List.map fst merged.last_seen_seq_by_room in
  assert_eq_list ~msg:"last_seen_seq_by_room from disk" [ "room-a"; "room-b" ] rooms;
  assert_true
    "caller's non-heartbeat fields still win (continuity_summary)"
    (merged.continuity_summary = "caller wrote this")
;;

(* --- version bump invariant ----------------------------------- *)

let test_merge_sets_meta_version_to_latest () =
  (* Required by write_meta's CAS: the merged payload must report the
     disk version so the next attempt passes. Check both strategies. *)
  let base = make_meta "k" in
  let caller = { base with meta_version = 1 } in
  let latest = { base with meta_version = 99 } in
  let a = Keeper_meta_merge.caller_wins ~latest ~caller in
  let b = Keeper_meta_merge.heartbeat_fields_from_disk ~latest ~caller in
  assert_eq_int ~msg:"caller_wins meta_version=latest" 99 a.meta_version;
  assert_eq_int ~msg:"heartbeat_fields_from_disk meta_version=latest" 99 b.meta_version
;;

(* --- idempotence when latest == caller ------------------------- *)

let test_merge_idempotent_no_race () =
  let base = make_meta "k" in
  let caller =
    { base with
      joined_room_ids = [ "r" ]
    ; last_seen_seq_by_room = [ "r", 3 ]
    ; meta_version = 7
    ; continuity_summary = "same"
    }
  in
  let latest = caller in
  let a = Keeper_meta_merge.caller_wins ~latest ~caller in
  let b = Keeper_meta_merge.heartbeat_fields_from_disk ~latest ~caller in
  assert_eq_int ~msg:"caller_wins no-op version" 7 a.meta_version;
  assert_eq_int ~msg:"heartbeat no-op version" 7 b.meta_version;
  assert_eq_list ~msg:"caller_wins no-op rooms" [ "r" ] a.joined_room_ids;
  assert_eq_list ~msg:"heartbeat no-op rooms" [ "r" ] b.joined_room_ids
;;

let () =
  test_caller_wins_overwrites_heartbeat_fields ();
  test_heartbeat_fields_from_disk ();
  test_merge_sets_meta_version_to_latest ();
  test_merge_idempotent_no_race ();
  print_endline "test_keeper_meta_merge: OK"
;;
