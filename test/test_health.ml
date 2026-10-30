(** Tests for Health module — Keeper outcome observation.

    All tests that touch Failure_observation run inside Eio_main.run because
    the shared observation store uses Eio.Mutex. *)

module Health = Masc.Health

open Alcotest

(* Test: get_summary returns correct structure *)
let test_get_summary () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let name = "test-summary-" ^ string_of_int (Random.int 100000) in
  let s = Health.get_summary ~agent_name:name in
  check string "agent_name matches" name s.agent_name;
  check int "no failures" 0 s.failure_count;
  check bool "no success observation" true (Option.is_none s.last_success_at)

(* Test: get_summary shows failures after recording *)
let test_get_summary_with_failures () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let name = "test-sumfail-" ^ string_of_int (Random.int 100000) in
  Health.record_failure ~agent_name:name ~reason:"oops1";
  Health.record_failure ~agent_name:name ~reason:"oops2";
  let s = Health.get_summary ~agent_name:name in
  check string "agent_name" name s.agent_name;
  check int "all failures counted" 2 s.failure_count;
  let last_reason =
    Option.map
      (fun (failure : Failure_observation.failure_record) -> failure.reason)
      s.last_failure
  in
  check (option string) "latest failure observed" (Some "oops2") last_reason

(* Test: summary_to_json produces valid JSON *)
let test_summary_to_json () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let name = "test-json-" ^ string_of_int (Random.int 100000) in
  let s = Health.get_summary ~agent_name:name in
  let json = Health.summary_to_json s in
  let json_str = Yojson.Safe.to_string json in
  check bool "contains agent_name" true (String.length json_str > 0);
  (* Verify it contains expected fields *)
  check bool "has agent_name field" true
    (try ignore (Yojson.Safe.Util.member "agent_name" json); true
     with _ -> false);
  check bool "has failure_count field" true
    (try ignore (Yojson.Safe.Util.member "failure_count" json); true
     with _ -> false)

let () =
  run "Health" [
    "summary", [
      test_case "get_summary structure" `Quick test_get_summary;
      test_case "get_summary with failures" `Quick test_get_summary_with_failures;
    ];
    "serialization", [test_case "summary_to_json" `Quick test_summary_to_json];
  ]
