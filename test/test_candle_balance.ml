open Alcotest
let payment goal amount =
  match Candle_payment.make
    ~identity:{goal_id=goal;request_id="request";verification_run_id="verified"}
    ~grade:Candle_grade.Trivial ~total_milli:amount
    ~grade_trace:{run_id="grade";slot_id="slot"}
    ~relations:[{task_id="task";relation=Candle_appraisal.Related;trace={run_id="relation";slot_id="slot"}}]
    ~weights_trace:{run_id="weights";slot_id="slot"}
    ~weight_max:1 ~deduction_rate:0 ~deduction_floor:1000 ~overdue_hours:0
    ~weights:["keeper",1] with
  | Ok value -> value | Error detail -> fail detail
let row payment =
  let at = match Candle_time.of_rfc3339 "2026-09-29T00:00:00Z" with
    | Ok at -> at | Error detail -> fail detail in
  let line = match Candle_event.to_line {at;body=Candle_event.Paid payment} with
    | Ok line -> line | Error detail -> fail detail in
  match Candle_event.of_line line with Ok row -> row | Error detail -> fail detail
let state rows = match Candle_balance.of_events rows with
  | Ok state -> state | Error error -> fail (Candle_balance.error_to_string error)
let test_cumulative_credit_boundary () =
  let amount = max_int / 1000 in
  let rows = List.init 1000 (fun i -> row (payment (string_of_int i) amount)) in
  let before = state rows in
  check int "all serialized payments accumulated exactly" (amount * 1000)
    (Candle_balance.balance before ~keeper:"keeper");
  let next = payment "overflow" amount in
  (match Candle_balance.credit before next with
   | Error (Candle_balance.Balance_overflow "keeper") -> ()
   | Ok _ | Error _ -> fail "cumulative overflow was accepted");
  (match Candle_balance.of_events (rows @ [row next]) with
   | Error (Candle_balance.Balance_overflow "keeper") -> ()
   | Ok _ | Error _ -> fail "an overflowing stored ledger was accepted");
  check int "refused credit preserves the prior balance" (amount * 1000)
    (Candle_balance.balance before ~keeper:"keeper")
let test_one_credit_per_goal () =
  let paid = payment "goal" 1000 in
  let before = state [row paid] in
  (match Candle_balance.credit before (payment "goal" 2000) with
   | Error (Candle_balance.Duplicate_payment "goal") -> ()
   | Ok _ | Error _ -> fail "a repeated Goal payment was accepted");
  check int "duplicate did not credit again" 1000
    (Candle_balance.balance before ~keeper:"keeper");
  check int "unmentioned Keeper has zero credit" 0
    (Candle_balance.balance before ~keeper:"other")
let () = run "candle_balance"
  ["ledger credits", [test_case "serialized payments cannot overflow a balance" `Quick test_cumulative_credit_boundary;
    test_case "a Goal is credited once" `Quick test_one_credit_per_goal]]
