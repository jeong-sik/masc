(** Test Board_curation — in-memory snapshot store *)

open Masc_mcp

let () = Mirage_crypto_rng_unix.use_default ()

(** {1 Snapshot lifecycle} *)

let test_initial_none () =
  Board_curation.reset_for_test ();
  Alcotest.(check (option pass)) "initially None"
    None (Board_curation.latest_snapshot ())

let test_submit_and_retrieve () =
  Board_curation.reset_for_test ();
  let snap : Board_curation.curation_snapshot = {
    id           = "cu-test-001";
    generated_at = 1_735_689_600.0;
    submitted_by = "agent-test";
    model        = Some "gpt-4o";
    ordering     = [ "p-aaa"; "p-bbb" ];
    highlights   = [ "p-aaa" ];
    rationale    = "Test rationale";
    provenance   = `Assoc [];
  } in
  Board_curation.submit_snapshot snap;
  let got = Board_curation.latest_snapshot () in
  Alcotest.(check bool) "snapshot present" true (Option.is_some got);
  let s = Option.get got in
  Alcotest.(check string) "id"           "cu-test-001"             s.id;
  Alcotest.(check string) "submitted_by" "agent-test"              s.submitted_by;
  Alcotest.(check (option string)) "model" (Some "gpt-4o")         s.model;
  Alcotest.(check (list string)) "ordering" [ "p-aaa"; "p-bbb" ]  s.ordering;
  Alcotest.(check string) "rationale"    "Test rationale"          s.rationale

let test_reset_clears () =
  Board_curation.reset_for_test ();
  let snap : Board_curation.curation_snapshot = {
    id           = "cu-test-002";
    generated_at = 1_735_689_600.0;
    submitted_by = "agent-test";
    model        = None;
    ordering     = [];
    highlights   = [];
    rationale    = "x";
    provenance   = `Assoc [];
  } in
  Board_curation.submit_snapshot snap;
  Alcotest.(check bool) "has snap" true (Option.is_some (Board_curation.latest_snapshot ()));
  Board_curation.reset_for_test ();
  Alcotest.(check (option pass)) "cleared after reset"
    None (Board_curation.latest_snapshot ())

let test_submit_replaces () =
  Board_curation.reset_for_test ();
  let make id rationale : Board_curation.curation_snapshot = {
    id; generated_at = 1_735_689_600.0; submitted_by = "a";
    model = None; ordering = []; highlights = []; rationale; provenance = `Assoc [];
  } in
  Board_curation.submit_snapshot (make "cu-first"  "first");
  Board_curation.submit_snapshot (make "cu-second" "second");
  let s = Option.get (Board_curation.latest_snapshot ()) in
  Alcotest.(check string) "latest id"       "cu-second" s.id;
  Alcotest.(check string) "latest rationale" "second"   s.rationale

(** {1 JSON serialisation} *)

let test_to_yojson_round_trip () =
  Board_curation.reset_for_test ();
  let snap : Board_curation.curation_snapshot = {
    id           = "cu-json-01";
    generated_at = 1_748_779_200.0;
    submitted_by = "model-agent";
    model        = Some "claude-3";
    ordering     = [ "p-1"; "p-2"; "p-3" ];
    highlights   = [ "p-2" ];
    rationale    = "Highlight active discussions first";
    provenance   = `Assoc [ ("source", `String "daily-batch") ];
  } in
  let json = Board_curation.snapshot_to_yojson snap in
  (match json with
   | `Assoc kvs ->
     let get k = List.assoc_opt k kvs in
     Alcotest.(check (option pass)) "id present"    (Some (`String "cu-json-01"))    (get "id");
     Alcotest.(check (option pass)) "model present" (Some (`String "claude-3"))      (get "model");
     Alcotest.(check bool) "ordering is list"
       true (match get "ordering" with Some (`List _) -> true | _ -> false);
   | _ -> Alcotest.fail "expected assoc")

let () =
  Alcotest.run "board_curation"
    [ "lifecycle",
      [ Alcotest.test_case "initially None"       `Quick test_initial_none
      ; Alcotest.test_case "submit and retrieve"  `Quick test_submit_and_retrieve
      ; Alcotest.test_case "reset clears"         `Quick test_reset_clears
      ; Alcotest.test_case "submit replaces prev" `Quick test_submit_replaces
      ]
    ; "serialisation",
      [ Alcotest.test_case "to_yojson round trip" `Quick test_to_yojson_round_trip
      ]
    ]
