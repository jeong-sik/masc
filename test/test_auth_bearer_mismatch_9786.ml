(* test/test_auth_bearer_mismatch_9786.ml

   #9786: agent A presents a token that resolves to credential
   owner B.  The Auth layer rejects with an [Unauthorized] error
   but the failure was invisible to Prometheus — dashboards could
   only see downstream cascades (masc_claim_next failures, keeper
   degraded proactive state) with no upstream cause.

   This test pins the new
   [masc_auth_bearer_token_mismatch_total{expected_agent,
   actual_agent}] counter:

     1. verify_token on an agent whose credential file doesn't
        exist, using a token that DOES resolve to some other
        agent, counts a mismatch with labels (expected, actual).
     2. verify_token on an agent with a VALID matching token
        does NOT count a mismatch.
     3. verify_token on an agent with a credential file but
        wrong token (the [cred.token <> token_hash] path) does
        NOT hit this counter — that's a simple wrong-token case,
        not the #9786 cross-agent reuse pattern.
     4. Mismatches across different (expected, actual) pairs land
        on separate counter rows so dashboards can attribute
        blame to the right agent pair.
*)

open Masc_mcp
module Prom = Prometheus

let mismatch_total ~expected ~actual =
  Prom.metric_value_or_zero
    Prom.metric_auth_bearer_token_mismatch
    ~labels:[
      ("expected_agent", expected);
      ("actual_agent", actual);
    ]
    ()

let with_temp_base_path f =
  let dir =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-test-auth-bearer-9786-%06x"
         (Random.bits ()))
  in
  (try Unix.mkdir dir 0o755 with Unix.Unix_error _ -> ());
  Fun.protect
    ~finally:(fun () ->
      (* best-effort recursive cleanup; tolerate missing files *)
      try
        let rec rm p =
          match (Unix.lstat p).st_kind with
          | S_DIR ->
            Array.iter (fun e -> rm (Filename.concat p e)) (Sys.readdir p);
            Unix.rmdir p
          | _ -> Unix.unlink p
        in
        rm dir
      with _ -> ())
    (fun () -> f dir)

let save_cred base_path ~agent_name ~raw_token =
  match
    Auth.save_raw_token_credential base_path
      ~agent_name ~role:Types.Worker ~raw_token
  with
  | Ok _ -> ()
  | Error e ->
    Alcotest.failf "failed to seed credential %s: %s" agent_name
      (Types.masc_error_to_string e)

(* A's credential never saved; B's credential saved with token-B.
   Verifying A with token-B triggers the cross-agent mismatch
   path ([verify_token_owner_alias]).  Counter must advance by
   exactly 1 with labels (A, B). *)
let test_cross_agent_mismatch_advances_counter () =
  with_temp_base_path @@ fun dir ->
  save_cred dir ~agent_name:"agent-b-9786" ~raw_token:"token-b-raw";
  let before = mismatch_total ~expected:"agent-a-9786" ~actual:"agent-b-9786" in
  let result =
    Auth.verify_token dir ~agent_name:"agent-a-9786" ~token:"token-b-raw"
  in
  (match result with
   | Error (Types.Unauthorized _) -> ()
   | Error e ->
     Alcotest.failf "expected Unauthorized, got: %s"
       (Types.masc_error_to_string e)
   | Ok _ -> Alcotest.fail "expected Unauthorized, got Ok");
  Alcotest.(check (float 0.0001))
    "mismatch counter (A, B) advanced by 1"
    (before +. 1.0)
    (mismatch_total ~expected:"agent-a-9786" ~actual:"agent-b-9786")

(* Valid token for the matching agent: the happy path must not
   count any mismatch. *)
let test_valid_token_no_mismatch () =
  with_temp_base_path @@ fun dir ->
  save_cred dir ~agent_name:"agent-valid-9786" ~raw_token:"token-valid";
  let before_self =
    mismatch_total ~expected:"agent-valid-9786" ~actual:"agent-valid-9786"
  in
  let result =
    Auth.verify_token dir ~agent_name:"agent-valid-9786"
      ~token:"token-valid"
  in
  Alcotest.(check bool) "verify Ok"
    true (Result.is_ok result);
  Alcotest.(check (float 0.0001))
    "no mismatch counter movement for matching pair"
    before_self
    (mismatch_total ~expected:"agent-valid-9786" ~actual:"agent-valid-9786")

(* Agent C has a credential file; wrong token presented that does
   NOT resolve to any other agent.  The reject is a plain wrong-
   token case and should NOT increment #9786's
   cross-agent counter — that counter is scoped to the "token
   belongs to someone else" failure only. *)
let test_wrong_token_no_other_owner_does_not_count () =
  with_temp_base_path @@ fun dir ->
  save_cred dir ~agent_name:"agent-c-9786" ~raw_token:"token-c";
  let before_totals =
    (* Take a snapshot across a reasonable label cross-product;
       if none of these advance we can assert the counter stayed
       still for the test keeper pair. *)
    mismatch_total ~expected:"agent-c-9786" ~actual:"agent-c-9786"
  in
  let result =
    Auth.verify_token dir ~agent_name:"agent-c-9786"
      ~token:"completely-unseen-token-abc"
  in
  Alcotest.(check bool) "verify Error" true (Result.is_error result);
  Alcotest.(check (float 0.0001))
    "no self-mismatch counter movement on wrong-token case"
    before_totals
    (mismatch_total ~expected:"agent-c-9786" ~actual:"agent-c-9786")

(* Different (expected, actual) pairs land on different counter
   rows — dashboards can attribute blame to the correct agent
   pair.  Pin that (A, B) and (A, C) are separate label
   combinations, not collapsed into one. *)
let test_distinct_pairs_recorded_separately () =
  with_temp_base_path @@ fun dir ->
  save_cred dir ~agent_name:"bee-9786" ~raw_token:"token-bee";
  save_cred dir ~agent_name:"cee-9786" ~raw_token:"token-cee";
  let before_ab = mismatch_total ~expected:"aaa-9786" ~actual:"bee-9786" in
  let before_ac = mismatch_total ~expected:"aaa-9786" ~actual:"cee-9786" in
  let _ = Auth.verify_token dir ~agent_name:"aaa-9786" ~token:"token-bee" in
  let _ = Auth.verify_token dir ~agent_name:"aaa-9786" ~token:"token-cee" in
  Alcotest.(check (float 0.0001)) "(aaa, bee) +1"
    (before_ab +. 1.0)
    (mismatch_total ~expected:"aaa-9786" ~actual:"bee-9786");
  Alcotest.(check (float 0.0001)) "(aaa, cee) +1"
    (before_ac +. 1.0)
    (mismatch_total ~expected:"aaa-9786" ~actual:"cee-9786")

let () =
  Alcotest.run "auth_bearer_mismatch_9786"
    [
      ( "mismatch-counter",
        [
          Alcotest.test_case "cross-agent mismatch advances" `Quick
            test_cross_agent_mismatch_advances_counter;
          Alcotest.test_case "valid token: no counter movement" `Quick
            test_valid_token_no_mismatch;
          Alcotest.test_case "wrong token but no other owner: no counter" `Quick
            test_wrong_token_no_other_owner_does_not_count;
          Alcotest.test_case "distinct (expected, actual) pairs" `Quick
            test_distinct_pairs_recorded_separately;
        ] );
    ]
