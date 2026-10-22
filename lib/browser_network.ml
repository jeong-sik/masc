let ( let* ) = Result.bind
let before_request_sent = "network.beforeRequestSent"
let response_completed = "network.responseCompleted"
let fetch_error = "network.fetchError"
let subscribed_methods = [ before_request_sent; response_completed; fetch_error ]
let requests_per_context = 200
let path_bytes_limit = 500
(* A header list is cut here; the row says how many names it has. *)
let header_names_limit = 64
let redacted_value = "REDACTED"

type outcome =
  | Pending
  | Completed of { status : int; mime_type : string; bytes_received : int; response_headers : string list; response_headers_total : int }
  | Failed of string

type request = {
  key : string;
  method_ : string;
  url : string;
  path_cut : bool;
  started : int;
  request_headers : string list;
  request_headers_total : int;
  mutable outcome : outcome;
}

(* Newest first. *)
type context_log = { mutable requests : request list; mutable kept : int; mutable dropped : int }
type t = {
  by_context : (string, context_log) Hashtbl.t;
  mutable unattributed : int;
  mutable malformed : int;
  mutable last_malformed : string option;
}

let create () = { by_context = Hashtbl.create 8; unattributed = 0; malformed = 0; last_malformed = None }
let field key = function `Assoc fields -> List.assoc_opt key fields | _ -> None
let string key json = match field key json with
  | Some (`String value) -> Ok value
  | _ -> Error ("BiDi network event missing string: " ^ key)
let integer key json = match field key json with
  | Some (`Int value) -> Ok value
  | _ -> Error ("BiDi network event missing integer: " ^ key)

let redact_url raw =
  match Uri.of_string raw with
  | exception Failure _ -> None
  | uri ->
    match Uri.scheme uri, Uri.host uri with
    (* data:, blob:, file: and the like have no host to name. What follows the scheme can be the whole
       payload, so only the scheme is kept. *)
    | Some scheme, (None | Some "") -> Some (scheme ^ ":", true)
    | Some scheme, Some host ->
      let path = Uri.path uri in
      let kept_path = String_util.utf8_prefix ~max_bytes:path_bytes_limit path in
      let query = Uri.query uri |> List.map (fun (name, values) -> name, List.map (fun _ -> redacted_value) values) in
      let bare = Uri.make ~scheme ~host ?port:(Uri.port uri) ~path:kept_path () in
      let bare = if query = [] then bare else Uri.with_query bare query in
      Some (Uri.to_string bare, String.length kept_path < String.length path)
    | None, _ -> None

let header_names headers =
  match headers with
  | Some (`List rows) ->
    let names = List.filter_map (fun row -> match field "name" row with Some (`String name) -> Some name | _ -> None) rows in
    Ok (List.filteri (fun index _ -> index < header_names_limit) names, List.length names)
  | Some _ -> Error "BiDi network event headers are not a list"
  | None -> Ok ([], 0)

let log_of (t : t) context =
  match Hashtbl.find_opt t.by_context context with
  | Some log -> log
  | None -> let log = { requests = []; kept = 0; dropped = 0 } in Hashtbl.replace t.by_context context log; log

let add log request =
  log.requests <- request :: log.requests;
  if log.kept < requests_per_context then log.kept <- log.kept + 1
  else begin
    log.requests <- List.filteri (fun index _ -> index < requests_per_context) log.requests;
    log.dropped <- log.dropped + 1
  end

(* [network.BaseParameters] allows a null context, for a request no tab is making. *)
let context_of params = match field "context" params with
  | Some (`String context) -> Ok (Some context)
  | Some `Null -> Ok None
  | _ -> Error "BiDi network event has no context or null"

let parse ~method_ params =
  if not (List.mem method_ subscribed_methods) then Error ("unsubscribed BiDi event: " ^ method_)
  else
  let* context = context_of params in
  let* raw = match field "request" params with Some request -> Ok request | None -> Error "BiDi network event missing request" in
  let* id = string "request" raw in
  let redirect = match field "redirectCount" params with Some (`Int count) -> count | _ -> 0 in
  let key = id ^ "#" ^ string_of_int redirect in
  let* request_method = string "method" raw in
  let* raw_url = string "url" raw in
  let* url, path_cut = Option.to_result ~none:"BiDi network event has a relative address" (redact_url raw_url) in
  let* started = integer "timestamp" params in
  let* request_headers, request_headers_total = header_names (field "headers" raw) in
  let* ending =
    if method_ = before_request_sent then Ok Pending
    else if method_ = response_completed then begin
      let* response = match field "response" params with Some response -> Ok response | None -> Error "BiDi network event missing response" in
      let* status = integer "status" response in
      let* mime_type = string "mimeType" response in
      let* bytes_received = integer "bytesReceived" response in
      let* response_headers, response_headers_total = header_names (field "headers" response) in
      Ok (Completed { status; mime_type; bytes_received; response_headers; response_headers_total })
    end else begin
      let* reason = string "errorText" params in
      Ok (Failed reason)
    end in
  Ok (context, { key; method_ = request_method; url; path_cut; started; request_headers; request_headers_total; outcome = ending })

let event (t : t) ~method_ params =
  match parse ~method_ params with
  | Error reason -> t.malformed <- t.malformed + 1; t.last_malformed <- Some reason
  | Ok (None, _) -> t.unattributed <- t.unattributed + 1
  | Ok (Some context, seen) ->
    let log = log_of t context in
    (match List.find_opt (fun request -> String.equal request.key seen.key) log.requests with
     | Some existing ->
       (* The start is already listed; only an end event changes how the request stands. *)
       (match seen.outcome with Pending -> () | Completed _ | Failed _ -> existing.outcome <- seen.outcome)
     | None ->
       (* When the first event seen is an end, the request began before this connection subscribed. *)
       add log seen)

let names_json names total =
  `Assoc [ "names", `List (List.map (fun name -> `String name) names); "total", `Int total ]

let request_json request =
  let base = [
    "method", `String request.method_;
    "url", `String request.url;
    "urlCut", `Bool request.path_cut;
    "timestamp", `Int request.started;
    "requestHeaders", names_json request.request_headers request.request_headers_total ] in
  let outcome = match request.outcome with
    | Pending -> [ "state", `String "pending" ]
    | Completed { status; mime_type; bytes_received; response_headers; response_headers_total } ->
      [ "state", `String "completed"; "status", `Int status; "mimeType", `String mime_type
      ; "bytesReceived", `Int bytes_received
      ; "responseHeaders", names_json response_headers response_headers_total ]
    | Failed reason -> [ "state", `String "failed"; "error", `String reason ] in
  `Assoc (base @ outcome)

let to_json (t : t) ~context =
  let requests, dropped = match Hashtbl.find_opt t.by_context context with
    | Some log -> List.rev log.requests, log.dropped
    | None -> [], 0 in
  `Assoc [ "requests", `List (List.map request_json requests); "dropped", `Int dropped
         ; "unattributedRequests", `Int t.unattributed
         ; "malformedEvents", `Assoc [ "count", `Int t.malformed
                                     ; "last", (match t.last_malformed with Some reason -> `String reason | None -> `Null) ] ]
