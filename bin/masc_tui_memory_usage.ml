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
  let ( let* ) = Result.bind in
  match json with
  | `Assoc fields ->
    let* () =
      match List.assoc_opt "keeper" fields with
      | Some (`String name) when String.equal name keeper -> Ok ()
      | Some _ | None -> Error "turn-records response does not identify this Keeper"
    in
    let* () =
      match List.assoc_opt "skipped_rows" fields with
      | Some (`Int 0) -> Ok ()
      | Some (`Int n) when n > 0 ->
          Error (Printf.sprintf "%d unreadable turn records; input statistics unavailable" n)
      | Some _ | None -> Error "turn-records response has no valid skipped-row count"
    in
    (match List.assoc_opt "entries" fields with
     | Some (`List entries) ->
       let rec read reversed = function
         | [] -> Ok (of_records (List.rev reversed))
         | `Assoc fields :: rest ->
           (match List.assoc_opt "record" fields with
            | None -> Error "turn-records entry is missing record"
            | Some json ->
              let* record = Turn_record.of_json json in
              if String.equal record.keeper keeper then read (record :: reversed) rest
              else Error "turn-records entry belongs to another Keeper")
         | _ :: _ -> Error "turn-records entry is not an object"
       in
       read [] entries
     | Some _ | None -> Error "turn-records response is missing entries")
  | _ -> Error "turn-records response is not an object"
