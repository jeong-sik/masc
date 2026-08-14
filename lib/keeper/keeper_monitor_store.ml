(** Durable store for RFC-0379 keeper monitors. *)

let store_path ~base_path =
  Filename.concat
    (Filename.concat (Common.masc_dir_from_base_path ~base_path) "monitors")
    "monitors-v1.json"
;;

let ( let* ) = Result.bind

let decode_records content =
  if String.equal (String.trim content) ""
  then Ok []
  else (
    match Yojson.Safe.from_string content with
    | `List items ->
      List.fold_left
        (fun acc item ->
           let* acc = acc in
           let* record = Monitor_domain.of_yojson item in
           Ok (record :: acc))
        (Ok [])
        items
      |> Result.map List.rev
    | _ -> Error "monitor store must be a JSON array"
    | exception Yojson.Json_error message ->
      Error (Printf.sprintf "monitor store is not valid JSON: %s" message))
;;

let encode_records records =
  Yojson.Safe.pretty_to_string
    (`List (List.map Monitor_domain.to_yojson records))
  ^ "\n"
;;

(* One locked read-decide-rewrite transaction over the whole store. [decide]
   returns the records to persist ([None] = no write) plus the caller value.
   Decode failure aborts the transaction: a malformed store is surfaced, never
   silently replaced. *)
let transact ~base_path decide =
  match
    Fs_compat.rewrite_private_file_durable_locked_result
      (store_path ~base_path)
      (fun existing ->
         match decode_records existing with
         | Error message -> None, Error message
         | Ok records ->
           (match decide records with
            | Error message -> None, Error message
            | Ok (None, value) -> None, Ok value
            | Ok (Some records', value) -> Some (encode_records records'), Ok value))
  with
  | Ok result -> result
  | Error message -> Error message
;;

let load ~base_path =
  transact ~base_path (fun records -> Ok (None, records))
;;

let create ~base_path (record : Monitor_domain.t) =
  transact ~base_path (fun records ->
    if List.exists (fun (r : Monitor_domain.t) -> String.equal r.id record.id) records
    then Error (Printf.sprintf "monitor id %s already exists" record.id)
    else (
      let owned =
        List.length
          (List.filter
             (fun (r : Monitor_domain.t) -> String.equal r.keeper record.keeper)
             records)
      in
      if owned >= Monitor_domain.max_active_monitors_per_keeper
      then
        Error
          (Printf.sprintf
             "keeper %s already holds %d active monitors (cap %d)"
             record.keeper
             owned
             Monitor_domain.max_active_monitors_per_keeper)
      else Ok (Some (records @ [ record ]), ())))
;;

let cancel ~base_path ~keeper ~id =
  transact ~base_path (fun records ->
    match
      List.find_opt (fun (r : Monitor_domain.t) -> String.equal r.id id) records
    with
    | None -> Ok (None, false)
    | Some record when not (String.equal record.keeper keeper) ->
      Error
        (Printf.sprintf "monitor %s belongs to keeper %s" id record.keeper)
    | Some _ ->
      let records' =
        List.filter (fun (r : Monitor_domain.t) -> not (String.equal r.id id)) records
      in
      Ok (Some records', true))
;;

type fire_outcome =
  | Fire_recorded_retained
  | Fire_recorded_removed

let record_fire ~base_path ~id =
  transact ~base_path (fun records ->
    match
      List.find_opt (fun (r : Monitor_domain.t) -> String.equal r.id id) records
    with
    | None -> Error (Printf.sprintf "monitor %s is no longer stored" id)
    | Some record ->
      let fired = { record with Monitor_domain.fired_count = record.fired_count + 1 } in
      if Monitor_domain.exhausted fired
      then (
        let records' =
          List.filter
            (fun (r : Monitor_domain.t) -> not (String.equal r.id id))
            records
        in
        Ok (Some records', Fire_recorded_removed))
      else (
        let records' =
          List.map
            (fun (r : Monitor_domain.t) -> if String.equal r.id id then fired else r)
            records
        in
        Ok (Some records', Fire_recorded_retained)))
;;

let remove_expired ~base_path ~now =
  transact ~base_path (fun records ->
    let expired, live =
      List.partition (fun record -> Monitor_domain.expired record ~now) records
    in
    match expired with
    | [] -> Ok (None, [])
    | _ ->
      Ok (Some live, List.map (fun (r : Monitor_domain.t) -> r.id) expired))
;;
