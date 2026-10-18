let read ~store ~limit =
  Result.map
    (fun rows ->
      let reversed, skipped =
        List.fold_left
          (fun (acc, skipped) -> function
            | Dated_jsonl.Malformed_json _ -> acc, skipped + 1
            | Dated_jsonl.Parsed json ->
              match Turn_record.of_json json with
              | Ok record -> record :: acc, skipped
              | Error _ -> acc, skipped + 1)
          ([], 0) rows
      in
      List.rev reversed, skipped)
    (Dated_jsonl.read_recent_result store limit)

type exact_error =
  | Store_read_failed of Dated_jsonl.read_error
  | Invalid_target_record of string
  | Uncertain_absence of { unidentified_rows : int }

let exact_error_to_string = function
  | Store_read_failed error -> Dated_jsonl.read_error_to_string error
  | Invalid_target_record detail -> "Invalid target turn record: " ^ detail
  | Uncertain_absence { unidentified_rows } ->
      Printf.sprintf
        "Cannot establish turn absence: %d rows could not be identified"
        unidentified_rows

let read_exact ~store ~keeper ~turn_ref =
  let skipped = ref 0 in
  let names_target = function
    | `Assoc fields ->
        List.exists
          (fun (name, value) ->
            String.equal name "turn_ref"
            && match Ids.Turn_ref.of_yojson value with
               | Ok candidate -> Ids.Turn_ref.equal candidate turn_ref
               | Error _ -> false)
          fields
    | _ -> false
  in
  let select = function
    | Dated_jsonl.Malformed_json _ -> incr skipped; None
    | Dated_jsonl.Parsed json ->
        (match Turn_record.of_json json with
         | Ok record when Ids.Turn_ref.equal record.turn_ref turn_ref ->
             if String.equal record.keeper keeper then Some (Ok record)
             else Some (Error (Invalid_target_record "Keeper does not match"))
         | Ok _ -> None
         | Error detail ->
             incr skipped;
             if names_target json then Some (Error (Invalid_target_record detail))
             else None)
  in
  match Dated_jsonl.find_latest_entry_result store select with
  | Error error -> Error (Store_read_failed error)
  | Ok (Some (Error error)) -> Error error
  | Ok (Some (Ok record)) -> Ok (Some record, !skipped)
  | Ok None when !skipped > 0 ->
      Error (Uncertain_absence { unidentified_rows = !skipped })
  | Ok None -> Ok (None, 0)
