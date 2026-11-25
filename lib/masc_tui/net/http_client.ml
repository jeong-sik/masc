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
  | Transport (Health.Timeout_detail { phase; after_sec; path }) ->
      Say.resolve Say.Lang_en
        (Health.timeout_detail_say ~phase ~after_sec ~path)
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

let default_max_body_bytes = 16 * 1024 * 1024
let max_error_json_parse_bytes = 65_536

let parse_api_error_opt body =
  if String.length body > max_error_json_parse_bytes then None
  else
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

let strip_ascii_control s =
  let len = String.length s in
  let buf = Buffer.create len in
  for i = 0 to len - 1 do
    let c = s.[i] in
    let code = Char.code c in
    if code >= 0x20 && code <> 0x7F then Buffer.add_char buf c
  done;
  Buffer.contents buf

let is_uri_scheme_start = function 'A' .. 'Z' | 'a' .. 'z' -> true | _ -> false

let is_uri_scheme_char = function
  | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '+' | '-' | '.' -> true
  | _ -> false

let uri_authority_start s =
  let len = String.length s in
  if len >= 2 && Char.equal s.[0] '/' && Char.equal s.[1] '/' then Some 2
  else if len >= 4 && is_uri_scheme_start s.[0] then
    let rec scan i =
      if
        i + 2 < len
        && Char.equal s.[i] ':'
        && Char.equal s.[i + 1] '/'
        && Char.equal s.[i + 2] '/'
      then Some (i + 3)
      else if i < len && is_uri_scheme_char s.[i] then scan (i + 1)
      else None
    in
    scan 1
  else None

let sanitize_timeout_path path =
  let cleaned = String.trim (strip_ascii_control path) in
  let len = String.length cleaned in
  let rec cutoff i =
    if i >= len then len
    else
      match cleaned.[i] with
      | '?' | '#' -> i
      | _ -> cutoff (i + 1)
  in
  let before_qf = String.sub cleaned 0 (cutoff 0) in
  let path_only =
    match uri_authority_start before_qf with
    | None -> before_qf
    | Some auth_idx ->
        let blen = String.length before_qf in
        if auth_idx >= blen then ""
        else
          match String.index_from_opt before_qf auth_idx '/' with
          | Some slash_idx -> String.sub before_qf slash_idx (blen - slash_idx)
          | None -> ""
  in
  String.trim path_only

let sanitized_path_opt = function
  | None -> None
  | Some p ->
      let clean = sanitize_timeout_path p in
      if String.equal clean "" then None else Some clean

let transport_error_of_connect_failure ~path ~cooldown_sec = function
  | Masc_http_client.Pool.Establishment_timeout -> (
      match cooldown_sec with
      | None ->
          Health.Timeout_detail
            {
              phase = Health.Timeout_connect;
              after_sec =
                Some
                  Masc_http_client.Pool.default_config.connect_timeout_seconds;
              path;
            }
      | Some retry_in_seconds ->
          let sec =
            if Float.is_finite retry_in_seconds && retry_in_seconds > 0.0 then
              retry_in_seconds
            else
              Masc_http_client.Pool.default_config
                .connect_failure_cooldown_seconds
          in
          Health.Timeout_detail
            {
              phase = Health.Timeout_connect_cooldown;
              after_sec = Some sec;
              path;
            })
  | Masc_http_client.Pool.Tcp_failure _ -> Health.Connect_refused
  | Masc_http_client.Pool.No_addresses -> Health.Other_io "no resolved addresses"
  | Masc_http_client.Pool.Dns_failure ex ->
      Health.Other_io ("DNS: " ^ Printexc.to_string ex)
  | Masc_http_client.Pool.Client_failure msg -> Health.Protocol_error msg

let transport_error_of_failure ?path ?(streaming = false) = function
  | Masc_http_client.Pool_unavailable ->
      Health.Other_io "HTTP client pool unavailable"
  | Masc_http_client.Request_failed err -> (
      let clean_path = sanitized_path_opt path in
      match err with
      | Masc_http_client.Pool.Connect_failed { failure; _ } ->
          transport_error_of_connect_failure ~path:clean_path ~cooldown_sec:None
            failure
      | Masc_http_client.Pool.Connect_held_back
          { failure; retry_in_seconds; _ } ->
          transport_error_of_connect_failure ~path:clean_path
            ~cooldown_sec:(Some retry_in_seconds) failure
      | Masc_http_client.Pool.Timed_out { after_seconds } ->
          let phase =
            if streaming then Health.Timeout_stream_header
            else Health.Timeout_response
          in
          Health.Timeout_detail
            { phase; after_sec = Some after_seconds; path = clean_path }
      | Masc_http_client.Pool.Idle_timed_out { after_seconds } ->
          Health.Timeout_detail
            {
              phase = Health.Timeout_stream_idle;
              after_sec = Some after_seconds;
              path = clean_path;
            }
      | Masc_http_client.Pool.Body_limit_exceeded { limit; _ } ->
          Health.Protocol_error
            (Printf.sprintf "response body exceeded %d byte limit" limit)
      | Masc_http_client.Pool.Exchange_failed msg -> Health.Protocol_error msg
      | Masc_http_client.Pool.Invalid_request _ ->
          Health.Protocol_error (Masc_http_client.Pool.request_error_to_string err))

let should_autostart_server ~contact ~already_attempted =
  Masc_server_lifecycle.start_due ~contact ~already_attempted

let send_raw ~io ~clock ?(timeout_sec = 10.0)
    ?(max_body_bytes = default_max_body_bytes) ?extra_headers ?content_type
    ~method_ ?body ep ~path =
  let url = build_url ep ~path in
  let headers = build_headers ?extra:extra_headers ?content_type ep in
  let result =
    Io_domain.run io (fun () ->
        Masc_http_client.request ~clock ~timeout_sec
          ~max_body_bytes ~method_ ~url ~headers ?body ())
  in
  match result with
  | Error failure ->
      Error
        (Transport (transport_error_of_failure ~path ~streaming:false failure))
  | Ok resp -> classify_response ep ~status:resp.status ~body:resp.body

let decode_body ~decode body =
  match Yojson.Safe.from_string body with
  | json -> (
      match decode json with
      | Ok v -> Ok v
      | Error msg -> Error (Decode_error msg))
  | exception Yojson.Json_error msg ->
      Error (Decode_error ("invalid JSON: " ^ msg))

let get_raw ~io ~clock ?timeout_sec ?max_body_bytes ?extra_headers ep ~path =
  send_raw ~io ~clock ?timeout_sec ?max_body_bytes ?extra_headers ~method_:`GET ep ~path

let post_raw ~io ~clock ?timeout_sec ?extra_headers ~content_type ~body ep ~path =
  send_raw ~io ~clock ?timeout_sec ?extra_headers ~content_type ~method_:`POST
    ~body ep ~path

let put_raw ~io ~clock ?timeout_sec ?extra_headers ~content_type ~body ep ~path =
  send_raw ~io ~clock ?timeout_sec ?extra_headers ~content_type ~method_:`PUT
    ~body ep ~path

let delete_raw ~io ~clock ?timeout_sec ?extra_headers ?content_type ?body ep
    ~path =
  send_raw ~io ~clock ?timeout_sec ?extra_headers ?content_type ~method_:`DELETE
    ?body ep ~path

let post_stream ~io ~clock ?(idle_timeout_sec = 120.0) ?header_timeout_sec
    ?(extra_headers = []) ~content_type ~body ~on_response ~on_chunk ep ~path =
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
          ?header_timeout_seconds:header_timeout_sec ~method_:`POST ~url
          ~headers ~body ~on_response ~on_chunk ())
  in
  match result with
  | Error failure ->
      Error
        (Transport (transport_error_of_failure ~path ~streaming:true failure))
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
