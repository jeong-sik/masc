type display_unit = Tokens | Bytes

let next_unit = function Tokens -> Bytes | Bytes -> Tokens
let unit_label = function Tokens -> "tokens" | Bytes -> "KiB"
let page_limit = 50

type distribution =
  { samples : int
  ; mean : float
  ; minimum : int
  ; maximum : int
  }

type reading =
  { distribution : distribution option
  ; last : int option
  }

type t =
  { records : int
  ; tokens : reading
  ; bytes : reading
  }

let summarize values =
  let distribution =
    List.fold_left
      (fun accumulated -> function
        | None -> accumulated
        | Some value ->
          Some
            (match accumulated with
             | None ->
               { samples = 1; mean = float value; minimum = value; maximum = value }
             | Some previous ->
               let samples = previous.samples + 1 in
               { samples
               ; mean = previous.mean +. (float value -. previous.mean) /. float samples
               ; minimum = min previous.minimum value
               ; maximum = max previous.maximum value
               }))
      None values
  in
  { distribution; last = List.fold_left (fun _ value -> value) None values }

let of_records records =
  let tokens (record : Turn_record.t) =
    match record.usage.scope with
    | Runtime_usage_scope.Per_request -> record.usage.input_tokens
    | Turn_total | Conversation_cumulative | Usage_scope_unavailable -> None
  in
  let bytes (record : Turn_record.t) =
    Option.map
      (fun (wire : Turn_record.request_wire_observation) -> wire.body_bytes)
      record.request_wire_observation
  in
  { records = List.length records
  ; tokens = summarize (List.map tokens records)
  ; bytes = summarize (List.map bytes records)
  }

let decode ~keeper json =
  Result.map of_records (Masc_tui_turn_record_page.decode ~keeper json)
