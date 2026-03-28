(** Token_usage_record — Parse token usage evidence from CDAL proof.

    @since CDAL eval content-based redesign *)

type t = {
  turn : int;
  input_tokens : int;
  output_tokens : int;
  cost_usd : float option;
}

let of_json (json : Yojson.Safe.t) : (t, string) result =
  match json with
  | `Assoc fields ->
    let get key = List.assoc_opt key fields in
    (match get "turn", get "input_tokens", get "output_tokens" with
     | Some (`Int turn), Some (`Int input_tokens), Some (`Int output_tokens) ->
       let cost_usd = match get "cost_usd" with
         | Some (`Float c) -> Some c
         | Some (`Int c) -> Some (Float.of_int c)
         | _ -> None
       in
       Ok { turn; input_tokens; output_tokens; cost_usd }
     | _ -> Error "missing required fields in token usage record")
  | _ -> Error "token usage record must be a JSON object"

let of_json_list (json : Yojson.Safe.t) : (t list, string) result =
  match json with
  | `List items ->
    let rec parse acc = function
      | [] -> Ok (List.rev acc)
      | item :: rest ->
        (match of_json item with
         | Ok v -> parse (v :: acc) rest
         | Error e -> Error e)
    in
    parse [] items
  | _ -> Error "expected JSON array of token usage records"

let total_tokens (records : t list) : int =
  List.fold_left (fun acc r -> acc + r.input_tokens + r.output_tokens) 0 records

let total_cost (records : t list) : float =
  List.fold_left (fun acc r ->
    match r.cost_usd with Some c -> acc +. c | None -> acc
  ) 0.0 records
