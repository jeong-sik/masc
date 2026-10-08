module Index = Keeper_tool_call_index

type history_generation = Initial | Rewritten of string

type t = { history_generation : history_generation; history_pairs : int; ledger_frontier : Index.frontier }
type error = Invalid_record of string

let error_to_string = function
  | Invalid_record detail -> "keeper repetition judged record: " ^ detail

let context_key = "keeper_repetition_boundary"
let empty = { history_generation = Initial; history_pairs = 0; ledger_frontier = Index.empty_frontier }

let generation_of_json = function
  | `Null -> Ok Initial
  | `String value ->
    Random_id.parse_uuid_v7 value
    |> Result.map (fun generation -> Rewritten generation)
    |> Result.map_error (fun detail -> Invalid_record detail)
  | _ -> Error (Invalid_record "invalid history generation")

let decode = function
  | `Assoc fields ->
    (match List.assoc_opt "history_generation" fields,
           List.assoc_opt "history_pairs" fields, List.assoc_opt "ledger_frontier" fields with
     | Some generation, Some (`Int history_pairs), Some ledger when history_pairs >= 0 ->
       Result.bind (generation_of_json generation) (fun history_generation ->
         Index.frontier_of_json ledger
         |> Result.map (fun ledger_frontier -> {history_generation; history_pairs; ledger_frontier})
         |> Result.map_error (fun detail -> Invalid_record detail))
     | _ -> Error (Invalid_record "expected history generation, nonnegative history_pairs and ledger_frontier"))
  | _ -> Error (Invalid_record "not an object")

let encode boundary = `Assoc
  [ "history_generation", (match boundary.history_generation with
      | Initial -> `Null | Rewritten generation -> `String generation)
  ; "history_pairs", `Int boundary.history_pairs
  ; "ledger_frontier", Index.frontier_to_json boundary.ledger_frontier ]

let read context =
  match Agent_core.Context.get_scoped context Agent_core.Context.Session context_key with
  | None -> Ok empty
  | Some json -> decode json

let record context boundary =
  Agent_core.Context.set_scoped context Agent_core.Context.Session context_key (encode boundary)

let reset_history context =
  Result.map (fun boundary ->
    let context = Agent_core.Context.copy context in
    record context { boundary with
      history_generation = Rewritten (Random_id.uuid_v7 ()); history_pairs = 0 };
    context) (read context)

let restore ~source ~target =
  match read source, read target with
  | Error _ as error, _ -> error
  | Ok _, (Error _ as error) -> error
  | Ok durable, Ok live ->
    let history =
      match Agent_core.Context.get_scoped source Agent_core.Context.Session context_key with
      | None -> live
      | Some _ when durable.history_generation = live.history_generation ->
        { durable with history_pairs = max durable.history_pairs live.history_pairs }
      | Some _ -> durable
    in
    let boundary =
      { history with
        ledger_frontier = Index.merge_frontiers durable.ledger_frontier live.ledger_frontier } in
    if boundary <> live then record target boundary;
    Ok boundary
;;

let seed_beyond ~judged pairs =
  let total = List.length pairs in
  let keep = max 0 (total - judged) in
  List.filteri (fun index _ -> index < keep) pairs
;;
