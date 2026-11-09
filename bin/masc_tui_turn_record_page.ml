let decode ~keeper json =
  let open Result.Syntax in
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
      | Some (`Int n) when n > 0 -> Error (Printf.sprintf "%d unreadable turn records" n)
      | Some _ | None -> Error "turn-records response has no valid skipped-row count"
    in
    (match List.assoc_opt "entries" fields with
     | Some (`List entries) ->
       let rec read reversed = function
         | [] -> Ok (List.rev reversed)
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
