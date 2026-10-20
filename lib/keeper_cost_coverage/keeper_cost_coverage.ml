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
  | Evidence_inconsistent

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
    if history = Complete && priced_readings = 0 && known_cost_usd <> 0.
    then Error Evidence_inconsistent
    else Ok {known_cost_usd; priced_readings; unpriced_readings;
             unresolved_readings; unobserved_attempts; history}

let knowledge state =
  match state.history with
  | Unobserved -> Unresolved
  | Complete ->
    if state.unresolved_readings > 0 || state.unobserved_attempts > 0 then Unresolved
    else if state.priced_readings = 0 then
      if state.unpriced_readings = 0 then No_observations else No_reported_prices
    else if state.unpriced_readings = 0 then Fully_priced else Partly_priced

let error_to_string = function
  | Invalid_cost -> "cost must be finite and non-negative"
  | Cost_overflow -> "reported cost sum overflow"
  | Count_overflow -> "cost coverage count overflow"
  | Evidence_regressed -> "cost coverage regressed"
  | History_rewritten -> "unobserved cost history was erased"
  | Evidence_inconsistent -> "cost increased without a priced reading"

let to_json state : Yojson.Safe.t =
  match state.history with
  | Unobserved when state.priced_readings = 0 && state.unpriced_readings = 0
                   && state.unresolved_readings = 0 && state.unobserved_attempts = 0 ->
    `Float state.known_cost_usd
  | Complete | Unobserved ->
    `Assoc
      [ "known_cost_usd", `Float state.known_cost_usd
      ; "priced_readings", `Int state.priced_readings
      ; "unpriced_readings", `Int state.unpriced_readings
      ; "unresolved_readings", `Int state.unresolved_readings
      ; "unobserved_attempts", `Int state.unobserved_attempts
      ; "history", `String (match state.history with
          | Complete -> "complete" | Unobserved -> "unobserved")
      ]

let field_names =
  [ "known_cost_usd"; "priced_readings"; "unpriced_readings"
  ; "unresolved_readings"; "unobserved_attempts"; "history" ]

let number = function
  | `Float value when valid_cost value -> Ok value
  | `Int value when value >= 0 -> Ok (float_of_int value)
  | `Float _ | `Int _ | `Intlit _ | `Null | `Bool _ | `String _
  | `Assoc _ | `List _ -> Error "cost must be a finite non-negative number"

let count name fields =
  match List.assoc_opt name fields with
  | Some (`Int value) when value >= 0 -> Ok value
  | Some (`Int _ | `Float _ | `Intlit _ | `Null | `Bool _ | `String _
         | `Assoc _ | `List _) | None ->
    Error (name ^ " must be a non-negative integer")

let of_json (json : Yojson.Safe.t) =
  match json with
  | `Float _ | `Int _ ->
    let* known_cost_usd = number json in
    Result.map_error error_to_string (unobserved_history ~known_cost_usd)
  | `Assoc fields ->
    let names = List.map fst fields in
    if List.sort String.compare names <> List.sort String.compare field_names
    then Error "cost coverage must have exactly its six fields, without duplicates"
    else
      let* known_cost_usd = number (List.assoc "known_cost_usd" fields) in
      let* priced_readings = count "priced_readings" fields in
      let* unpriced_readings = count "unpriced_readings" fields in
      let* unresolved_readings = count "unresolved_readings" fields in
      let* unobserved_attempts = count "unobserved_attempts" fields in
      let* history = match List.assoc "history" fields with
        | `String "complete" -> Ok Complete
        | `String "unobserved" -> Ok Unobserved
        | `String _ | `Null | `Bool _ | `Int _ | `Float _ | `Intlit _
        | `Assoc _ | `List _ -> Error "unknown cost history"
      in
      if history = Complete && priced_readings = 0 && known_cost_usd <> 0.
      then Error (error_to_string Evidence_inconsistent)
      else Ok { known_cost_usd; priced_readings; unpriced_readings;
                unresolved_readings; unobserved_attempts; history }
  | `Intlit _ | `Null | `Bool _ | `String _ | `List _ ->
    Error "cost coverage must be a number or an exact coverage object"
