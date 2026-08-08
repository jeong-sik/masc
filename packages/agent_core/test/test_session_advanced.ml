(** Advanced tests for Session module — checkpoint, metadata, edge cases.

    Extends test_session.ml with:
    - Checkpoint roundtrip and resume lineage
    - Metadata evolution across turns
    - JSON edge cases *)

open Alcotest
open Agent_sdk

(* ── Session metadata ────────────────────────────────── *)

let test_metadata_survives_record_turn () =
  let s = Session.create ~id:"meta-test" () in
  Context.set s.metadata "key" (`String "value");
  let s = Session.record_turn s in
  let s = Session.record_turn s in
  check int "turn_count" 2 s.turn_count;
  match Context.get s.metadata "key" with
  | Some (`String "value") -> ()
  | _ -> fail "metadata lost after record_turn"
;;

let test_multiple_record_turns () =
  let s = Session.create () in
  let s = ref s in
  for _ = 1 to 10 do
    s := Session.record_turn !s
  done;
  check int "10 turns" 10 !s.turn_count
;;

let test_elapsed_increases () =
  Eio_main.run
  @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  let s = Session.create () in
  let e1 = Session.elapsed s in
  Eio.Time.sleep clock 0.02;
  let e2 = Session.elapsed s in
  check bool "elapsed increases" true (e2 > e1)
;;

(* ── Checkpoint roundtrip ────────────────────────────── *)

let test_checkpoint_roundtrip () =
  let s = Session.create ~id:"cp-test" ~cwd:"/home" () in
  let s = Session.record_turn s in
  let s = Session.record_turn s in
  Context.set s.metadata "pref" (`String "dark");
  let json = Session.to_json s in
  match Session.of_json json with
  | Ok s2 ->
    check string "id preserved" s.id s2.id;
    check int "turn_count preserved" 2 s2.turn_count;
    check (option string) "cwd preserved" (Some "/home") s2.cwd;
    (match Context.get s2.metadata "pref" with
     | Some (`String "dark") -> ()
     | _ -> fail "metadata lost in roundtrip")
  | Error _ -> fail "of_json failed"
;;

let test_resume_from_lineage () =
  let s1 = Session.create ~id:"s1" () in
  let s2 = Session.create ~id:"s2" ~resumed_from:s1.id () in
  let s3 = Session.create ~id:"s3" ~resumed_from:s2.id () in
  check (option string) "s2 from s1" (Some "s1") s2.resumed_from;
  check (option string) "s3 from s2" (Some "s2") s3.resumed_from
;;

let test_resume_preserves_turn_count () =
  let s = Session.create ~id:"resume-tc" () in
  let s = Session.record_turn s in
  let s = Session.record_turn s in
  let s = Session.record_turn s in
  let json = Session.to_json s in
  match Session.of_json json with
  | Ok s2 ->
    check int "turn_count 3" 3 s2.turn_count;
    let s3 = Session.create ~resumed_from:s2.id () in
    check (option string) "resumed_from" (Some s2.id) s3.resumed_from
  | Error _ -> fail "of_json failed"
;;

(* ── JSON edge cases ─────────────────────────────────── *)

let test_of_json_missing_fields () =
  let bad = `Assoc [ "not_id", `Int 42 ] in
  check bool "is error" true (Result.is_error (Session.of_json bad))
;;

let test_of_json_extra_fields () =
  let s = Session.create ~id:"extra-test" () in
  let json = Session.to_json s in
  (* Add extra fields *)
  let extended =
    match json with
    | `Assoc fields -> `Assoc (("extra_field", `String "hello") :: fields)
    | other -> other
  in
  match Session.of_json extended with
  | Ok s2 -> check string "id" "extra-test" s2.id
  | Error _ -> fail "extra fields should be ignored"
;;

let test_empty_metadata_roundtrip () =
  let s = Session.create ~id:"empty-meta" () in
  let json = Session.to_json s in
  match Session.of_json json with
  | Ok s2 ->
    check string "id" "empty-meta" s2.id;
    (* Empty metadata should not cause issues *)
    check bool "no keys" true (Context.get s2.metadata "nonexistent" = None)
  | Error _ -> fail "empty metadata roundtrip failed"
;;

let test_touch_updates () =
  Eio_main.run
  @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  let s = Session.create () in
  let t1 = s.last_active_at in
  Eio.Time.sleep clock 0.01;
  let s = Session.touch s in
  check bool "touch updated" true (s.last_active_at >= t1)
;;

(* ── Suite ───────────────────────────────────────────── *)

let () =
  run
    "session_advanced"
    [ ( "session_metadata"
      , [ test_case
            "metadata survives record_turn"
            `Quick
            test_metadata_survives_record_turn
        ; test_case "multiple record turns" `Quick test_multiple_record_turns
        ; test_case "elapsed increases" `Quick test_elapsed_increases
        ] )
    ; ( "checkpoint"
      , [ test_case "roundtrip" `Quick test_checkpoint_roundtrip
        ; test_case "resume lineage" `Quick test_resume_from_lineage
        ; test_case "resume preserves turn_count" `Quick test_resume_preserves_turn_count
        ] )
    ; ( "json_edge"
      , [ test_case "missing fields" `Quick test_of_json_missing_fields
        ; test_case "extra fields" `Quick test_of_json_extra_fields
        ; test_case "empty metadata" `Quick test_empty_metadata_roundtrip
        ; test_case "touch updates" `Quick test_touch_updates
        ] )
    ]
;;
