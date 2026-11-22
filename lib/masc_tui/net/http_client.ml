open Masc_tui_core
open Masc_tui_protocol

let expected_instance_header = "X-Masc-Expected-Instance"
let expected_workspace_header = "X-Masc-Expected-Workspace"

type workspace_guard = {
  expected_instance : string option;
  expected_workspace : string option;
}

let no_guard = { expected_instance = None; expected_workspace = None }

type endpoint = {
  scheme : string;
  host : string;
  port : int;
  bearer_token : string option;
  guard : workspace_guard;
}

let make_endpoint ?(scheme = "http") ~host ~port ?bearer_token
    ?(guard = no_guard) () =
  { scheme; host; port; bearer_token; guard }

let with_guard ep guard = { ep with guard }

type http_error =
  | Transport of Health.transport_error
  | Workspace_mismatch of {
      expected_instance : string option;
      observed_instance : string option;
      observed_workspace_sha256 : string option;
      message : string;
    }
  | Http_error of {
      status : int;
      body : string;
      api_error : Wire_common.api_error option;
    }
  | Decode_error of string

let http_error_to_string = function
  | Transport Health.Connect_refused -> "connection refused"
  | Transport Health.Timeout -> "request timed out"
  | Transport (Health.Http_status code) -> Printf.sprintf "HTTP %d" code
  | Transport Health.Stream_eof -> "stream ended unexpectedly"
  | Transport (Health.Protocol_error msg) -> "protocol error: " ^ msg
  | Transport (Health.Other_io msg) -> "I/O error: " ^ msg
  | Workspace_mismatch
      {
        expected_instance;
        observed_instance;
        observed_workspace_sha256 = _;
        message;
      } ->
      Printf.sprintf "workspace mismatch (%s -> %s): %s"
        (Option.value ~default:"?" expected_instance)
        (Option.value ~default:"?" observed_instance)
        message
  | Http_error { status; api_error = Some err; _ } ->
      Printf.sprintf "HTTP %d (%s): %s" status
        (Wire_common.api_error_code_to_string err.code)
        err.message
  | Http_error { status; body; api_error = None } ->
      Printf.sprintf "HTTP %d: %s" status body
  | Decode_error msg -> "decode error: " ^ msg

(* RFC 7230 token characters allowed in HTTP header field-names. *)
let is_header_name_char = function
  | '!' | '#' | '$' | '%' | '&' | '\'' | '*' | '+' | '-' | '.' | '^' | '_' | '`'
  | '|' | '~' | '0' .. '9' | 'A' .. 'Z' | 'a' .. 'z' ->
      true
  | _ -> false

let sanitize_header_name name =
  let trimmed = String.trim name in
  let len = String.length trimmed in
  if len = 0 then None
  else
    let rec check i =
      if i = len then Some trimmed
      else if is_header_name_char trimmed.[i] then check (i + 1)
      else None
    in
    check 0

(* Strip NUL and all ASCII control characters (< 0x20 and 0x7F); fold CR/LF/TAB
   to a single space before trimming. *)
let sanitize_header_value value =
  let buf = Buffer.create (String.length value) in
  String.iter
    (fun c ->
      let code = Char.code c in
      if c = '\r' || c = '\n' || c = '\t' then Buffer.add_char buf ' '
      else if code < 0x20 || code = 0x7F then ()
      else Buffer.add_char buf c)
    value;
  String.trim (Buffer.contents buf)

let nonblank_opt = function
  | None -> None
  | Some raw ->
      let s = sanitize_header_value raw in
      if String.equal s "" then None else Some s

let build_url ep ~path =
  let clean_path =
    if String.length path > 0 && path.[0] = '/' then path else "/" ^ path
  in
  Printf.sprintf "%s://%s:%d%s" ep.scheme ep.host ep.port clean_path

let build_headers ?(extra = []) ?content_type ep =
  let has_header name lst =
    let target = String.lowercase_ascii name in
    List.exists (fun (k, _) -> String.equal (String.lowercase_ascii k) target) lst
  in
  let sanitized_extra =
    List.filter_map
      (fun (k, v) ->
        match sanitize_header_name k with
        | None -> None
        | Some clean_k -> Some (clean_k, sanitize_header_value v))
      extra
  in
  let acc = ref sanitized_extra in
  let add_if_missing name value_opt =
    match value_opt with
    | None -> ()
    | Some v ->
        if not (has_header name !acc) then acc := (name, v) :: !acc
  in
  add_if_missing "Accept" (Some "application/json");
  add_if_missing "Content-Type" (nonblank_opt content_type);
  add_if_missing expected_instance_header
    (nonblank_opt ep.guard.expected_instance);
  add_if_missing expected_workspace_header
    (nonblank_opt ep.guard.expected_workspace);
  (match nonblank_opt ep.bearer_token with
  | None -> ()
  | Some tok -> add_if_missing "Authorization" (Some ("Bearer " ^ tok)));
  !acc

let parse_api_error_opt body =
  match Yojson.Safe.from_string body with
  | json -> (
      match Wire_common.decode_api_error json with
      | Ok err -> Some err
      | Error _ -> None)
  | exception Yojson.Json_error _ -> None

let classify_response ep ~status ~body =
  if status >= 200 && status <= 299 then Ok body
  else
    let api_error = parse_api_error_opt body in
    match (status, api_error) with
    | 409, Some ({ code = Wire_common.Workspace_mismatch; _ } as err) ->
        let expected_instance =
          match err.expected_instance with
          | Some _ as v -> v
          | None -> ep.guard.expected_instance
        in
        Error
          (Workspace_mismatch
             {
               expected_instance;
               observed_instance = err.observed_instance;
               observed_workspace_sha256 = err.observed_workspace_sha256;
               message = err.message;
             })
    | ( _
      , Some
          {
            code =
              ( Wire_common.Invalid_param | Wire_common.Unauthorized
              | Wire_common.Not_found | Wire_common.Conflict_cas
              | Wire_common.Validation_failed | Wire_common.Store_unavailable
              | Wire_common.Other_code _ );
            _;
          } )
    | _, Some { code = Wire_common.Workspace_mismatch; _ }
    | _, None ->
        Error (Http_error { status; body; api_error })

let transport_error_of_connect_failure = function
  | Masc_http_client.Pool.Establishment_timeout -> Health.Timeout
  | Masc_http_client.Pool.Tcp_failure _ -> Health.Connect_refused
  | Masc_http_client.Pool.No_addresses -> Health.Other_io "no resolved addresses"
  | Masc_http_client.Pool.Dns_failure ex ->
      Health.Other_io ("DNS: " ^ Printexc.to_string ex)
  | Masc_http_client.Pool.Client_failure msg -> Health.Protocol_error msg

let transport_error_of_failure = function
  | Masc_http_client.Pool_unavailable ->
      Health.Other_io "HTTP client pool unavailable"
  | Masc_http_client.Request_failed err -> (
      match err with
      | Masc_http_client.Pool.Connect_failed { failure; _ } ->
          transport_error_of_connect_failure failure
      | Masc_http_client.Pool.Connect_held_back { failure; _ } ->
          transport_error_of_connect_failure failure
      | Masc_http_client.Pool.Timed_out _
      | Masc_http_client.Pool.Idle_timed_out _ ->
          Health.Timeout
      | Masc_http_client.Pool.Body_limit_exceeded { status; _ } ->
          Health.Http_status status
      | Masc_http_client.Pool.Exchange_failed msg -> Health.Protocol_error msg
      | Masc_http_client.Pool.Invalid_request _ ->
          Health.Protocol_error (Masc_http_client.Pool.request_error_to_string err))

let should_autostart_server ~contact ~already_attempted =
  Masc_server_lifecycle.start_due ~contact ~already_attempted

let send_raw ~io ~clock ?(timeout_sec = 10.0) ?extra_headers ?content_type
    ~method_ ?body ep ~path =
  let url = build_url ep ~path in
  let headers = build_headers ?extra:extra_headers ?content_type ep in
  let result =
    Io_domain.run io (fun () ->
        Masc_http_client.request ~clock ~timeout_sec ~method_ ~url ~headers
          ?body ())
  in
  match result with
  | Error failure -> Error (Transport (transport_error_of_failure failure))
  | Ok resp -> classify_response ep ~status:resp.status ~body:resp.body

let decode_body ~decode body =
  match Yojson.Safe.from_string body with
  | json -> (
      match decode json with
      | Ok v -> Ok v
      | Error msg -> Error (Decode_error msg))
  | exception Yojson.Json_error msg ->
      Error (Decode_error ("invalid JSON: " ^ msg))

let get_raw ~io ~clock ?timeout_sec ?extra_headers ep ~path =
  send_raw ~io ~clock ?timeout_sec ?extra_headers ~method_:`GET ep ~path

let post_raw ~io ~clock ?timeout_sec ?extra_headers ~content_type ~body ep ~path =
  send_raw ~io ~clock ?timeout_sec ?extra_headers ~content_type ~method_:`POST
    ~body ep ~path

let post_stream ~io ~clock ?(idle_timeout_sec = 120.0) ?(extra_headers = [])
    ~content_type ~body ~on_response ~on_chunk ep ~path =
  let url = build_url ep ~path in
  let headers =
    build_headers
      ~extra:(("Accept", "text/event-stream") :: extra_headers)
      ~content_type ep
  in
  let result =
    Io_domain.run io (fun () ->
        Masc_http_client.request_stream
          ~retention:Masc_http_client.Pool.Discard_body ~clock ~idle_timeout_sec
          ~method_:`POST ~url ~headers ~body ~on_response ~on_chunk ())
  in
  match result with
  | Error failure -> Error (Transport (transport_error_of_failure failure))
  | Ok (Masc_http_client.Pool.Streamed _) -> Ok ()
  | Ok (Masc_http_client.Pool.Buffered resp) -> (
      match classify_response ep ~status:resp.status ~body:resp.body with
      | Ok _ -> Ok ()
      | Error _ as err -> err)

let get_json ~io ~clock ?timeout_sec ep ~path ~decode =
  match get_raw ~io ~clock ?timeout_sec ep ~path with
  | Error _ as err -> err
  | Ok body -> decode_body ~decode body

let post_json ~io ~clock ?timeout_sec ep ~path ~body ~decode =
  let body_str = Yojson.Safe.to_string body in
  match
    send_raw ~io ~clock ?timeout_sec ~content_type:"application/json"
      ~method_:`POST ~body:body_str ep ~path
  with
  | Error _ as err -> err
  | Ok resp_body -> decode_body ~decode resp_body

let put_json ~io ~clock ?timeout_sec ep ~path ~body ~decode =
  let body_str = Yojson.Safe.to_string body in
  match
    send_raw ~io ~clock ?timeout_sec ~content_type:"application/json"
      ~method_:`PUT ~body:body_str ep ~path
  with
  | Error _ as err -> err
  | Ok resp_body -> decode_body ~decode resp_body

let delete_json ~io ~clock ?timeout_sec ?body ep ~path ~decode =
  let body_str = Option.map Yojson.Safe.to_string body in
  let content_type =
    match body_str with Some _ -> Some "application/json" | None -> None
  in
  match
    send_raw ~io ~clock ?timeout_sec ?content_type ~method_:`DELETE
      ?body:body_str ep ~path
  with
  | Error _ as err -> err
  | Ok resp_body -> decode_body ~decode resp_body
