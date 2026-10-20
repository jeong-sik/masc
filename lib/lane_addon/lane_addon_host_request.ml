let ( let* ) = Result.bind

type t =
  | Exact_output of Lane_addon_exact.request
  | Read_records of { request_id : string; source_id : string; after : string option }
  | Read_file of { request_id : string; source_id : string; commit : string; path : string }
  | Read_result of { request_id : string; original_request_id : string; source_id : string option;
                     sha256 : string; offset : int }
  | Ask of { request_id : string; questions : Keeper_ask.question list; context : string option }
  | Withdraw_ask of { request_id : string; ask_id : string; reason : string }

let request_id = function
  | Exact_output request -> request.Lane_addon_exact.request_id
  | Read_records { request_id; _ } | Read_file { request_id; _ }
  | Read_result { request_id; _ } | Ask { request_id; _ }
  | Withdraw_ask { request_id; _ } -> request_id

let to_json = function
  | Exact_output request -> Lane_addon_exact.request_to_json request
  | Read_records {request_id; source_id; after} ->
      `Assoc ["kind", `String "read_records"; "request_id", `String request_id;
        "source_id", `String source_id; "after", Option.fold ~none:`Null ~some:(fun s -> `String s) after]
  | Read_file {request_id; source_id; commit; path} ->
      `Assoc ["kind", `String "read_file"; "request_id", `String request_id;
        "source_id", `String source_id; "commit", `String commit; "path", `String path]
  | Read_result {request_id; original_request_id; source_id; sha256; offset} ->
      `Assoc ["kind", `String "read_result"; "request_id", `String request_id;
        "original_request_id", `String original_request_id;
        "source_id", Option.fold ~none:`Null ~some:(fun s -> `String s) source_id;
        "sha256", `String sha256; "offset", `Int offset]
  | Ask {request_id; questions; context} ->
      `Assoc ["kind", `String "ask"; "request_id", `String request_id;
        "questions", `List (List.map Keeper_ask.question_to_json questions);
        "context", Option.fold ~none:`Null ~some:(fun value -> `String value) context]
  | Withdraw_ask {request_id; ask_id; reason} ->
      `Assoc ["kind", `String "withdraw_ask"; "request_id", `String request_id;
        "ask_id", `String ask_id; "reason", `String reason]

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

let read_result fields =
  let keys = ["kind"; "request_id"; "original_request_id"; "source_id"; "sha256"; "offset"] in
  if List.sort String.compare (List.map fst fields) <> List.sort String.compare keys then
    Error "read_result requires exactly kind, request_id, original_request_id, source_id, sha256 and offset"
  else
    let* request_id = text fields "request_id" in
    let* original_request_id = text fields "original_request_id" in
    let* source_id = match List.assoc_opt "source_id" fields with
      | Some `Null -> Ok None
      | Some (`String source) when String.trim source <> "" -> Ok (Some source)
      | Some _ | None -> Error "source_id must name the original source or be null for source-free requests" in
    let* sha256 = text fields "sha256" in
    let* () = if String.length sha256 = 64 && String.for_all
        (function '0'..'9' | 'a'..'f' -> true | _ -> false) sha256 then Ok ()
      else Error "sha256 requires the advertised lowercase SHA-256" in
    let* offset = match List.assoc_opt "offset" fields with
      | Some (`Int offset) when offset >= 0 -> Ok offset
      | Some _ | None -> Error "offset must be a nonnegative integer" in
    Ok (Read_result {request_id; original_request_id; source_id; sha256; offset})

let ask fields =
  match List.find_opt (fun (key, _) -> not (List.mem key [ "kind"; "request_id"; "questions"; "context" ])) fields with
  | Some (key, _) -> Error ("an ask request has no key " ^ key)
  | None ->
    let* request_id = text fields "request_id" in
    let* questions =
      Lane_addon_asks.questions_of_json (Option.value (List.assoc_opt "questions" fields) ~default:`Null)
    in
    let* context =
      match List.assoc_opt "context" fields with
      | None | Some `Null -> Ok None
      | Some (`String context) -> Ok (Some context)
      | Some _ -> Error "context must be a string or null"
    in
    Ok (Ask { request_id; questions; context })

let withdraw_ask fields =
  match List.find_opt (fun (key, _) -> not (List.mem key [ "kind"; "request_id"; "ask_id"; "reason" ])) fields with
  | Some (key, _) -> Error ("a withdraw_ask request has no key " ^ key)
  | None ->
    let* request_id = text fields "request_id" in
    let* ask_id = text fields "ask_id" in
    let* reason = text fields "reason" in
    Ok (Withdraw_ask { request_id; ask_id; reason })

let request_of_json = function
  | `Assoc fields as json ->
    (match List.assoc_opt "kind" fields with
     | Some (`String "exact_output") ->
       Lane_addon_exact.request_of_json json |> Result.map (fun request -> Exact_output request)
     | Some (`String "read_records") -> read_records fields
     | Some (`String "read_file") -> read_file fields
     | Some (`String "read_result") -> read_result fields
     | Some (`String "ask") -> ask fields
     | Some (`String "withdraw_ask") -> withdraw_ask fields
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
