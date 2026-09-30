module Names = Map.Make (String)
module Goals = Set.Make (String)
type t = { balances : int Names.t; paid_goals : Goals.t }
type error = Duplicate_payment of string | Balance_overflow of string
let error_to_string = function
  | Duplicate_payment goal -> "duplicate payment for Goal " ^ goal
  | Balance_overflow keeper -> "cumulative Candle balance overflows for " ^ keeper
let empty = { balances = Names.empty; paid_goals = Goals.empty }
let balance state ~keeper =
  match Names.find_opt keeper state.balances with Some amount -> amount | None -> 0
let credit state (payment : Candle_payment.t) =
  let goal = payment.identity.goal_id in
  if Goals.mem goal state.paid_goals then Error (Duplicate_payment goal)
  else
    let rec add balances = function
      | [] -> Ok { balances; paid_goals = Goals.add goal state.paid_goals }
      | (allocation : Candle_payment.allocation) :: rest ->
        let current = match Names.find_opt allocation.keeper balances with
          | Some amount -> amount | None -> 0 in
        if allocation.amount_milli > max_int - current then
          Error (Balance_overflow allocation.keeper)
        else add (Names.add allocation.keeper (current + allocation.amount_milli) balances) rest in
    add state.balances payment.allocations
let of_events events =
  List.fold_left (fun result (event : Candle_event.t) ->
    Result.bind result (fun state -> match event.body with
      | Candle_event.Paid payment -> credit state payment
      | Candle_event.Snapshot _ | Candle_event.Payout_owed _ | Candle_event.Candidates _
      | Candle_event.Unattributed _ | Candle_event.Payout_failed _ -> Ok state)) (Ok empty) events
