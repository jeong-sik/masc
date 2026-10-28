module Share = Masc.Published_artifact_share

let id = "artifact-" ^ String.make 32 'a'
let operation suffix = "01890e2a-4c8e-7b21-9f3c-" ^ suffix
let request operation_id expected_version requested =
  { Share.operation_id; expected_version; requested; expected_artifact_revision = 1;
    expected_artifact_sha256 = String.make 64 'a' }
let ok = function
  | Ok value -> value
  | Error (Share.Invalid detail) -> Alcotest.fail detail
  | Error Share.Operation_reused -> Alcotest.fail "operation id reused"
let record state request =
  match Share.apply state ~publication_matches:true request |> ok with
  | Recorded (state, receipt) -> state, receipt
  | Replay _ -> Alcotest.fail "expected a newly recorded request"

let test_latest_receipt_and_competing_changes () =
  let open Alcotest in
  let initial = Share.initial ~id ~shared:false |> ok in
  let enable = request (operation "000000000001") 0 true in
  let first, accepted = record initial enable in
  check bool "first change enables sharing" true (Share.snapshot first).shared;
  check int "first change advances version" 1 (Share.snapshot first).version;
  let stale = request (operation "000000000002") 0 false in
  let second, rejected = record first stale in
  (match rejected.outcome with
   | Conflict { version = 1; shared = true } -> ()
   | Applied _ | Conflict _ -> fail "stale change did not retain its original conflict");
  (match Share.apply second ~publication_matches:true stale |> ok with
   | Replay receipt when receipt = rejected -> ()
   | Recorded _ | Replay _ -> fail "latest conflict did not replay");
  let third, _ = record second (request (operation "000000000003") 1 false) in
  check bool "a later change revokes sharing" false (Share.snapshot third).shared;
  (match Share.apply first ~publication_matches:true enable |> ok with
   | Replay receipt when receipt = accepted -> ()
   | Recorded _ | Replay _ -> fail "latest accepted operation did not replay");
  (match Share.apply first ~publication_matches:true { enable with requested = false } with
   | Error Share.Operation_reused -> ()
   | Error (Share.Invalid _) | Ok _ -> fail "a reused operation id accepted different input");
  check int "two accepted changes survive the ABA sequence" 2 (Share.snapshot third).version;
  let recovered = Share.of_json (Share.to_json third) |> ok in
  check bool "recovered state matches" true (Share.snapshot recovered = Share.snapshot third);
  check bool "recovered latest receipt is preserved" true
    (Share.latest recovered = Share.latest third)

let test_noop_and_future_conflict () =
  let open Alcotest in
  let state = Share.initial ~id ~shared:false |> ok in
  let future = request (operation "000000000004") 1 true in
  let state, future_receipt = record state future in
  (match future_receipt.outcome with
   | Conflict { version = 0; shared = false } -> ()
   | Applied _ | Conflict _ -> fail "future expected version did not conflict");
  (match Share.apply state ~publication_matches:true future |> ok with
   | Replay receipt when receipt = future_receipt -> ()
   | Recorded _ | Replay _ -> fail "latest future conflict did not replay");
  let state, _ = record state (request (operation "000000000005") 0 false) in
  check int "same-value accepted write still advances version" 1 (Share.snapshot state).version;
  check bool "no-op remains private" false (Share.snapshot state).shared

let test_legacy_and_corruption () =
  let open Alcotest in
  let legacy = `Assoc ["id", `String id; "shared", `Bool true] in
  let state = Share.of_json legacy |> ok in
  check bool "legacy shared state is preserved" true (Share.snapshot state).shared;
  check int "legacy state starts at version zero" 0 (Share.snapshot state).version;
  let state, _ = record state (request (operation "000000000006") 0 false) in
  let json = Share.to_json state in
  (match Share.of_json json with Ok restored ->
      check bool "new state round trips" true (Share.snapshot restored = Share.snapshot state)
   | Error _ -> fail "new share history did not round trip");
  let corrupt = match json with
    | `Assoc fields -> `Assoc (List.map (fun (name, value) ->
        if name = "snapshot" then name, `Assoc ["version", `Int 1; "shared", `Bool true]
        else name, value) fields)
    | _ -> fail "expected JSON object" in
  (match Share.of_json corrupt with
   | Error (Invalid _) -> ()
   | Error Operation_reused | Ok _ -> fail "inconsistent history was accepted");
  (match Share.apply state ~publication_matches:true (request "not-a-uuid" 1 true) with
   | Error (Invalid _) -> ()
   | Error Operation_reused | Ok _ -> fail "invalid operation id was accepted")

let test_publication_precondition () =
  let open Alcotest in
  let state = Share.initial ~id ~shared:false |> ok in
  let operation = request (operation "000000000007") 0 true in
  let state, receipt = match Share.apply state ~publication_matches:false operation |> ok with
    | Recorded (state, receipt) -> state, receipt
    | Replay _ -> fail "new operation replayed" in
  (match receipt.outcome with
   | Conflict { version = 0; shared = false } -> ()
   | Applied _ | Conflict _ -> fail "changed publication was exposed");
  (match Share.apply state ~publication_matches:true operation |> ok with
   | Replay replayed when replayed = receipt -> ()
   | Recorded _ | Replay _ -> fail "publication conflict did not remain bound");
  check bool "publication conflict survives encoding" true
    (Share.of_json (Share.to_json state) |> ok |> Share.latest = Some receipt)

let () =
  Alcotest.run "artifact external sharing history"
    ["changes", [
      Alcotest.test_case "latest receipt and competing ABA changes" `Quick test_latest_receipt_and_competing_changes;
      Alcotest.test_case "no-op and future conflict remain bound" `Quick test_noop_and_future_conflict;
      Alcotest.test_case "changed publication is a replayable conflict" `Quick test_publication_precondition;
      Alcotest.test_case "legacy and corrupt storage" `Quick test_legacy_and_corruption]]
