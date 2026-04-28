type t = {
  tokens : int;
  turns : int;
  time_ms : int;
  cost_usd : float;
}

let make ~tokens ~turns ~time_ms ~cost_usd =
  { tokens; turns; time_ms; cost_usd }

let zero = { tokens = 0; turns = 0; time_ms = 0; cost_usd = 0.0 }

let is_exhausted t =
  t.tokens <= 0 || t.turns <= 0 || t.time_ms <= 0

let sub_tokens t n = { t with tokens = t.tokens - n }

let sub_turns t n = { t with turns = t.turns - n }

let sub_time_ms t n = { t with time_ms = t.time_ms - n }

let sub_cost_usd t f = { t with cost_usd = t.cost_usd -. f }

let compare a b =
  let c = Int.compare a.tokens b.tokens in
  if c <> 0 then c
  else
    let c = Int.compare a.turns b.turns in
    if c <> 0 then c
    else
      let c = Int.compare a.time_ms b.time_ms in
      if c <> 0 then c
      else Float.compare a.cost_usd b.cost_usd

let equal a b =
  a.tokens = b.tokens
  && a.turns = b.turns
  && a.time_ms = b.time_ms
  && Float.equal a.cost_usd b.cost_usd

let to_json t =
  `Assoc [
    "tokens", `Int t.tokens;
    "turns", `Int t.turns;
    "time_ms", `Int t.time_ms;
    "cost_usd", `Float t.cost_usd;
  ]

let of_json = function
  | `Assoc fields ->
    let get_int k =
      match List.assoc_opt k fields with
      | Some (`Int i) -> Ok i
      | Some _ -> Error (Printf.sprintf "Budget.of_json: %s not int" k)
      | None -> Error (Printf.sprintf "Budget.of_json: missing %s" k)
    in
    let get_float k =
      match List.assoc_opt k fields with
      | Some (`Float f) -> Ok f
      | Some (`Int i) -> Ok (float_of_int i)
      | Some _ -> Error (Printf.sprintf "Budget.of_json: %s not float" k)
      | None -> Error (Printf.sprintf "Budget.of_json: missing %s" k)
    in
    (match get_int "tokens", get_int "turns", get_int "time_ms", get_float "cost_usd" with
     | Ok tokens, Ok turns, Ok time_ms, Ok cost_usd ->
       Ok { tokens; turns; time_ms; cost_usd }
     | Error e, _, _, _
     | _, Error e, _, _
     | _, _, Error e, _
     | _, _, _, Error e -> Error e)
  | _ -> Error "Budget.of_json: expected object"
