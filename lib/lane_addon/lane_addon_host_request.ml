let ( let* ) = Result.bind

type t =
  | Exact_output of Lane_addon_exact.request
  | Read_records of { request_id : string; source_id : string; after : string option }
  | Read_file of { request_id : string; source_id : string; commit : string; path : string }

let request_id = function
  | Exact_output request -> request.Lane_addon_exact.request_id
  | Read_records { request_id; _ } | Read_file { request_id; _ } -> request_id

let text fields key =
  match List.assoc_opt key fields with
  | Some (`String value) when String.trim value <> "" -> Ok value
  | Some _ | None -> Error (key ^ " requires a non-blank string")

let read_records fields =
  match List.find_opt (fun (key, _) -> not (List.mem key [ "kind"; "request_id"; "source_id"; "after" ])) fields with
  | Some (key, _) -> Error ("a read_records request has no key " ^ key)
  | None ->
    let* request_id = text fields "request_id" in
    let* source_id = text fields "source_id" in
    let* after =
      match List.assoc_opt "after" fields with
      | None | Some `Null -> Ok None
      | Some (`String cursor) -> Ok (Some cursor)
      | Some _ -> Error "after must be a cursor string or null"
    in
    Ok (Read_records { request_id; source_id; after })

let read_file fields =
  match List.find_opt (fun (key, _) -> not (List.mem key [ "kind"; "request_id"; "source_id"; "commit"; "path" ])) fields with
  | Some (key, _) -> Error ("a read_file request has no key " ^ key)
  | None ->
    let* request_id = text fields "request_id" in
    let* source_id = text fields "source_id" in
    let* commit = text fields "commit" in
    let* path = text fields "path" in
    Ok (Read_file { request_id; source_id; commit; path })

let request_of_json = function
  | `Assoc fields as json ->
    (match List.assoc_opt "kind" fields with
     | Some (`String "exact_output") ->
       Lane_addon_exact.request_of_json json |> Result.map (fun request -> Exact_output request)
     | Some (`String "read_records") -> read_records fields
     | Some (`String "read_file") -> read_file fields
     | Some (`String kind) -> Error ("this host has no request kind " ^ kind)
     | Some _ | None -> Error "a host request requires a string kind")
  | _ -> Error "a host request must be an object"

let listing_of_json = function
  | `Assoc [ "requests", `List values ] ->
    let* requests =
      List.fold_right
        (fun value acc ->
           let* acc = acc in
           let* request = request_of_json value in
           Ok (request :: acc))
        values (Ok [])
    in
    let ids = List.map request_id requests in
    if List.length (List.sort_uniq String.compare ids) <> List.length ids
    then Error "a listing names the same request id twice"
    else Ok requests
  | _ -> Error "a host request listing must be exactly {\"requests\": [...]}"

let result_arguments ~request_id ~result = `Assoc [ "request_id", `String request_id; "result", result ]

let accepted_of_json = function
  | `Assoc [ "accepted", `Bool accepted ] -> Ok accepted
  | _ -> Error "lane_host_result must answer exactly {\"accepted\": bool}"
