type observation =
  | Priced of float
  | Price_not_reported
  | Usage_unresolved
  | Attempt_unobserved

type history = Complete | Unobserved

type t =
  { known_cost_usd : float
  ; priced_readings : int
  ; unpriced_readings : int
  ; unresolved_readings : int
  ; unobserved_attempts : int
  ; history : history
  }

type knowledge =
  | No_observations
  | Fully_priced
  | No_reported_prices
  | Partly_priced
  | Unresolved

type error =
  | Invalid_cost
  | Cost_overflow
  | Count_overflow
  | Evidence_regressed
  | History_rewritten

let empty =
  { known_cost_usd = 0.
  ; priced_readings = 0
  ; unpriced_readings = 0
  ; unresolved_readings = 0
  ; unobserved_attempts = 0
  ; history = Complete
  }

let ( let* ) = Result.bind

let valid_cost amount = Float.is_finite amount && amount >= 0.

let unobserved_history ~known_cost_usd =
  if valid_cost known_cost_usd
  then Ok { empty with known_cost_usd; history = Unobserved }
  else Error Invalid_cost

let add_count left right =
  if left > max_int - right then Error Count_overflow else Ok (left + right)

let add left right =
  let known_cost_usd = left.known_cost_usd +. right.known_cost_usd in
  if not (Float.is_finite known_cost_usd)
  then Error Cost_overflow
  else
    let* priced_readings = add_count left.priced_readings right.priced_readings in
    let* unpriced_readings = add_count left.unpriced_readings right.unpriced_readings in
    let* unresolved_readings = add_count left.unresolved_readings right.unresolved_readings in
    let* unobserved_attempts = add_count left.unobserved_attempts right.unobserved_attempts in
    let history = match left.history, right.history with
      | Complete, Complete -> Complete
      | Unobserved, (Complete | Unobserved) | Complete, Unobserved -> Unobserved
    in
    Ok { known_cost_usd; priced_readings; unpriced_readings;
         unresolved_readings; unobserved_attempts; history }

let observe state observation =
  let* delta = match observation with
    | Priced amount ->
      if valid_cost amount then Ok {empty with known_cost_usd = amount; priced_readings = 1}
      else Error Invalid_cost
    | Price_not_reported -> Ok {empty with unpriced_readings = 1}
    | Usage_unresolved -> Ok {empty with unresolved_readings = 1}
    | Attempt_unobserved -> Ok {empty with unobserved_attempts = 1}
  in
  add state delta

let subtract_count before after =
  if after < before then Error Evidence_regressed else Ok (after - before)

let difference ~before ~after =
  let known_cost_usd = after.known_cost_usd -. before.known_cost_usd in
  if known_cost_usd < 0.
  then Error Evidence_regressed
  else
    let* priced_readings = subtract_count before.priced_readings after.priced_readings in
    let* unpriced_readings = subtract_count before.unpriced_readings after.unpriced_readings in
    let* unresolved_readings = subtract_count before.unresolved_readings after.unresolved_readings in
    let* unobserved_attempts = subtract_count before.unobserved_attempts after.unobserved_attempts in
    let* history = match before.history, after.history with
      | Complete, Complete | Unobserved, Unobserved -> Ok Complete
      | Complete, Unobserved -> Ok Unobserved
      | Unobserved, Complete -> Error History_rewritten
    in
    Ok {known_cost_usd; priced_readings; unpriced_readings;
        unresolved_readings; unobserved_attempts; history}

let knowledge state =
  match state.history with
  | Unobserved -> Unresolved
  | Complete ->
    if state.unresolved_readings > 0 || state.unobserved_attempts > 0 then Unresolved
    else if state.priced_readings = 0 then
      if state.unpriced_readings = 0 then No_observations else No_reported_prices
    else if state.unpriced_readings = 0 then Fully_priced else Partly_priced
