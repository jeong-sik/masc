open Server_utils
open Server_auth

module Http = Http_server_eio

let upload_permission = Masc_domain.CanBroadcast
let read_permission = Masc_domain.CanReadState
let immutable_cache_control = "private, max-age=31536000, immutable"
let multipart_overhead_bytes = 64 * 1024

let attachment_security_headers ~etag ~disposition request =
  [ "x-content-type-options", "nosniff"
  ; "content-security-policy", "default-src 'none'; sandbox"
  ; "etag", "\"" ^ etag ^ "\""
  ; "cache-control", immutable_cache_control
  ; "content-disposition", disposition
  ]
  @ admitted_cors_headers request
;;

let not_modified_headers ~etag request =
  [ "etag", "\"" ^ etag ^ "\""
  ; "cache-control", immutable_cache_control
  ; "x-content-type-options", "nosniff"
  ]
  @ admitted_cors_headers request
;;

let has_non_ascii s =
  let len = String.length s in
  let rec loop i =
    if i >= len
    then false
    else if Char.code s.[i] >= 0x80
    then true
    else loop (i + 1)
  in
  loop 0
;;

let is_rfc5987_attr_char = function
  | 'A' .. 'Z'
  | 'a' .. 'z'
  | '0' .. '9'
  | '!' | '#' | '$' | '&' | '+' | '-' | '.' | '^' | '_' | '`' | '|' | '~' -> true
  | _ -> false
;;

let rfc5987_pct_encode s =
  let buf = Buffer.create (String.length s * 3) in
  String.iter
    (fun c ->
       if is_rfc5987_attr_char c
       then Buffer.add_char buf c
       else Buffer.add_string buf (Printf.sprintf "%%%02X" (Char.code c)))
    s;
  Buffer.contents buf
;;

let ascii_fallback_filename ~fallback_name fname =
  let buf = Buffer.create (String.length fname) in
  let prev_underscore = ref false in
  String.iter
    (fun c ->
       let code = Char.code c in
       if code >= 0x20
          && code <= 0x7e
          && c <> '"'
          && c <> '\''
          && c <> ';'
          && c <> '/'
          && c <> '\\'
       then (
         Buffer.add_char buf c;
         prev_underscore := c = '_')
       else if not !prev_underscore
       then (
         Buffer.add_char buf '_';
         prev_underscore := true))
    fname;
  let candidate = String.trim (Buffer.contents buf) in
  let stem =
    match String.rindex_opt candidate '.' with
    | Some idx -> String.sub candidate 0 idx
    | None -> candidate
  in
  let has_ascii_alnum s =
    let len = String.length s in
    let rec loop i =
      if i >= len
      then false
      else (
        match s.[i] with
        | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' -> true
        | _ -> loop (i + 1))
    in
    loop 0
  in
  if has_ascii_alnum stem then candidate else fallback_name
;;

let content_disposition_of ~download ~(meta : Attachment_store.meta) =
  let ext =
    match meta.mime_type with
    | "image/png" -> ".png"
    | "image/jpeg" -> ".jpg"
    | "image/webp" -> ".webp"
    | "image/gif" -> ".gif"
    | "application/pdf" -> ".pdf"
    | "audio/mpeg" -> ".mp3"
    | "audio/wav" -> ".wav"
    | "audio/ogg" -> ".ogg"
    | "audio/midi" -> ".mid"
    | "audio/mp4" -> ".m4a"
    | "audio/webm" -> ".webm"
    | _ -> ".bin"
  in
  let fallback_name = meta.id ^ ext in
  let fname =
    match Option.bind meta.filename Attachment_store.sanitize_filename with
    | Some f -> f
    | None -> fallback_name
  in
  let disp = if download then "attachment" else "inline" in
  if has_non_ascii fname
  then (
    let ascii_name = ascii_fallback_filename ~fallback_name fname in
    let encoded = rfc5987_pct_encode fname in
    Printf.sprintf "%s; filename=\"%s\"; filename*=UTF-8''%s" disp ascii_name encoded)
  else Printf.sprintf "%s; filename=\"%s\"" disp fname
;;

(* --- Multipart/form-data parser (RFC 7578) --- *)

type multipart_file =
  { data : string
  ; filename : string option
  ; content_type : string option
  }

let unquote_param value =
  let s = String.trim value in
  let len = String.length s in
  if len >= 2 && s.[0] = '"' && s.[len - 1] = '"'
  then String.sub s 1 (len - 2)
  else s
;;

let extract_boundary content_type =
  let parts = String.split_on_char ';' content_type in
  match parts with
  | [] -> None
  | media :: params ->
    if not (String.equal (String.lowercase_ascii (String.trim media)) "multipart/form-data")
    then None
    else
      List.find_map
        (fun param ->
           match String.index_opt param '=' with
           | None -> None
           | Some eq ->
             let k = String.lowercase_ascii (String.trim (String.sub param 0 eq)) in
             if String.equal k "boundary"
             then (
               let v =
                 unquote_param
                   (String.sub param (eq + 1) (String.length param - eq - 1))
               in
               if String.equal v "" then None else Some v)
             else None)
        params
;;

let find_sub ~needle ~haystack ~from =
  let nlen = String.length needle in
  let hlen = String.length haystack in
  if nlen = 0
  then Some from
  else if from < 0 || from + nlen > hlen
  then None
  else (
    let rec loop i =
      if i + nlen > hlen
      then None
      else (
        let rec eq j =
          if j >= nlen
          then true
          else if haystack.[i + j] = needle.[j]
          then eq (j + 1)
          else false
        in
        if eq 0 then Some i else loop (i + 1))
    in
    loop from)
;;

let split_headers_and_body part =
  match find_sub ~needle:"\r\n\r\n" ~haystack:part ~from:0 with
  | Some i ->
    Some (String.sub part 0 i, String.sub part (i + 4) (String.length part - i - 4))
  | None ->
    (match find_sub ~needle:"\n\n" ~haystack:part ~from:0 with
     | Some i ->
       Some (String.sub part 0 i, String.sub part (i + 2) (String.length part - i - 2))
     | None -> None)
;;

let parse_part_headers raw =
  let lines =
    String.split_on_char '\n' raw
    |> List.map (fun l ->
      let len = String.length l in
      if len > 0 && l.[len - 1] = '\r' then String.sub l 0 (len - 1) else l)
  in
  List.filter_map
    (fun line ->
       match String.index_opt line ':' with
       | None -> None
       | Some idx ->
         let k = String.lowercase_ascii (String.trim (String.sub line 0 idx)) in
         let v = String.trim (String.sub line (idx + 1) (String.length line - idx - 1)) in
         Some (k, v))
    lines
;;

let parse_disposition_params value =
  let segments = String.split_on_char ';' value in
  let find_param target =
    List.find_map
      (fun seg ->
         match String.index_opt seg '=' with
         | None -> None
         | Some eq ->
           let k = String.lowercase_ascii (String.trim (String.sub seg 0 eq)) in
           if String.equal k target
           then (
             let v =
               unquote_param (String.sub seg (eq + 1) (String.length seg - eq - 1))
             in
             Some v)
           else None)
      segments
  in
  find_param "name", find_param "filename"
;;

let strip_leading_crlf s =
  if String.starts_with ~prefix:"\r\n" s
  then String.sub s 2 (String.length s - 2)
  else if String.starts_with ~prefix:"\n" s
  then String.sub s 1 (String.length s - 1)
  else s
;;

let strip_trailing_crlf s =
  let len = String.length s in
  if len >= 2 && s.[len - 2] = '\r' && s.[len - 1] = '\n'
  then String.sub s 0 (len - 2)
  else if len >= 1 && s.[len - 1] = '\n'
  then String.sub s 0 (len - 1)
  else s
;;

let parse_multipart ~boundary body =
  let delim = "--" ^ boundary in
  let delim_len = String.length delim in
  match find_sub ~needle:delim ~haystack:body ~from:0 with
  | None -> Error "multipart boundary not found in request body"
  | Some first ->
    let rec collect pos acc =
      let after = pos + delim_len in
      if after + 2 <= String.length body && String.sub body after 2 = "--"
      then Ok (List.rev acc)
      else (
        let part_start =
          if after + 2 <= String.length body && String.sub body after 2 = "\r\n"
          then after + 2
          else if after + 1 <= String.length body && body.[after] = '\n'
          then after + 1
          else after
        in
        match find_sub ~needle:delim ~haystack:body ~from:part_start with
        | None -> Error "unterminated multipart body (missing closing boundary)"
        | Some next ->
          let raw_part =
            String.sub body part_start (next - part_start) |> strip_trailing_crlf
          in
          collect next (raw_part :: acc))
    in
    (match collect first [] with
     | Error _ as err -> err
     | Ok parts ->
       let file_part = ref None in
       let explicit_filename = ref None in
       List.iter
         (fun raw_part ->
            let part = strip_leading_crlf raw_part in
            match split_headers_and_body part with
            | None -> ()
            | Some (hdr_raw, part_body) ->
              let hdrs = parse_part_headers hdr_raw in
              (match List.assoc_opt "content-disposition" hdrs with
               | None -> ()
               | Some disp ->
                 let name_opt, fname_opt = parse_disposition_params disp in
                 (match name_opt with
                  | Some "file" ->
                    let ct = List.assoc_opt "content-type" hdrs in
                    file_part := Some (part_body, fname_opt, ct)
                  | Some "filename" -> explicit_filename := Some (String.trim part_body)
                  | Some _ | None -> ())))
         parts;
       (match !file_part with
        | None -> Error "multipart/form-data request missing 'file' part"
        | Some (data, fname_opt, content_type) ->
          let filename =
            match !explicit_filename with
            | Some f when not (String.equal f "") -> Some f
            | Some _ | None -> fname_opt
          in
          Ok { data; filename; content_type }))
;;

let respond_err ~status ~code ~message ?(extra = []) request reqd =
  respond_json_value_with_cors
    ~status
    request
    reqd
    (`Assoc ([ "ok", `Bool false; "code", `String code; "error", `String message ] @ extra))
;;

let put_error_http = function
  | Attachment_store.Empty_payload ->
    `Bad_request, "empty_upload", Attachment_store.put_error_to_string Empty_payload, []
  | Attachment_store.Payload_too_large { actual; maximum } as err ->
    ( `Payload_too_large
    , "payload_too_large"
    , Attachment_store.put_error_to_string err
    , [ "bytes", `Int actual; "maximum_bytes", `Int maximum ] )
  | Attachment_store.Forbidden_mime _ as err ->
    `Unsupported_media_type, "forbidden_mime", Attachment_store.put_error_to_string err, []
  | Attachment_store.Unsupported_or_unknown_format _ as err ->
    `Unsupported_media_type, "unsupported_format", Attachment_store.put_error_to_string err, []
  | Attachment_store.Mime_mismatch _ as err ->
    `Unsupported_media_type, "mime_mismatch", Attachment_store.put_error_to_string err, []
  | Attachment_store.Invalid_keeper_name _ as err ->
    `Bad_request, "invalid_keeper", Attachment_store.put_error_to_string err, []
  | Attachment_store.Store_io_failed _ as err ->
    `Internal_server_error, "store_io_failed", Attachment_store.put_error_to_string err, []
;;

let handle_upload state request reqd =
  let base_path = (Mcp_server.workspace_config state).base_path in
  let max_attachment = Attachment_store.max_bytes () in
  let declared_len =
    Option.bind (Http.Request.header request "content-length") int_of_string_opt
  in
  let content_type_hdr = Http.Request.header request "content-type" in
  let is_multipart =
    match content_type_hdr with
    | Some ct -> Option.is_some (extract_boundary ct)
    | None -> false
  in
  let read_limit =
    if is_multipart then max_attachment + multipart_overhead_bytes else max_attachment
  in
  let created_by =
    sanitized_dashboard_actor_for_request ~base_path request
    |> Option.value ~default:"operator"
  in
  Http.Request.read_body_async_with_limit
    reqd
    ~max_bytes:read_limit
    ~on_body:(fun raw_body ->
      let received = String.length raw_body in
      match declared_len with
      | Some declared when declared <> received ->
        respond_err
          ~status:`Bad_request
          ~code:"truncated_upload"
          ~message:"upload ended before its Content-Length"
          ~extra:[ "declared_bytes", `Int declared; "received_bytes", `Int received ]
          request
          reqd
      | Some _ | None ->
        let header_filename () =
          Option.map Uri.pct_decode (Http.Request.header request "x-filename")
        in
        let extracted =
          match content_type_hdr with
          | Some ct ->
            (match extract_boundary ct with
             | Some boundary ->
               Result.map
                 (fun (mf : multipart_file) ->
                    ( mf.data
                    , mf.content_type
                    , (match mf.filename with
                       | Some _ as f -> f
                       | None -> header_filename ()) ))
                 (parse_multipart ~boundary raw_body)
             | None -> Ok (raw_body, Some ct, header_filename ()))
          | None -> Ok (raw_body, None, header_filename ())
        in
        (match extracted with
         | Error msg ->
           respond_err ~status:`Bad_request ~code:"invalid_multipart" ~message:msg request reqd
         | Ok (bytes, declared_mime, filename) ->
           (* Public HTTP uploads ALWAYS enforce [User_upload] + [Durable],
              ignoring any untrusted client origin/retention/keeper headers. *)
           let result =
             Eio_unix.run_in_systhread (fun () ->
               let store = Attachment_store.create ~base_path in
               Attachment_store.put
                 ~max_bytes:max_attachment
                 ?declared_mime
                 ?filename
                 ~origin:Attachment_store.User_upload
                 ~created_by
                 ~retention:Attachment_store.Durable
                 store
                 ~bytes)
           in
           (match result with
            | Ok meta ->
              respond_json_value_with_cors
                ~status:`Created
                request
                reqd
                (`Assoc
                   [ "ok", `Bool true
                   ; "data", Attachment_store.meta_to_wire_json meta
                   ])
            | Error err ->
              let status, code, message, extra = put_error_http err in
              respond_err ~status ~code ~message ~extra request reqd)))
    ~on_error:(function
      | Http.Request.Too_large maximum ->
        respond_err
          ~status:`Payload_too_large
          ~code:"payload_too_large"
          ~message:"upload exceeds attachment size limit"
          ~extra:[ "maximum_bytes", `Int maximum ]
          request
          reqd
      | Http.Request.Internal exn ->
        Log.Misc.error "attachment upload body read failed: %s" (Printexc.to_string exn);
        respond_err
          ~status:`Internal_server_error
          ~code:"upload_read_failed"
          ~message:"attachment upload failed"
          request
          reqd)
;;

type fetch_query =
  { download : bool
  ; target_format : Attachment_store.target_format
  ; max_px : int option
  }

let parse_fetch_query (request : Httpun.Request.t) =
  let uri = Uri.of_string request.target in
  let download =
    match Uri.get_query_param uri "download" with
    | Some ("1" | "true" | "TRUE") -> true
    | Some _ | None -> false
  in
  let format_res =
    match Uri.get_query_param uri "format" with
    | None | Some "" -> Ok Attachment_store.Native_format
    | Some raw ->
      (match String.lowercase_ascii (String.trim raw) with
       | "png" -> Ok Attachment_store.Force_png
       | other -> Error (Printf.sprintf "unsupported format %S (supported: png)" other))
  in
  let max_px_res =
    match Uri.get_query_param uri "max_px" with
    | None | Some "" -> Ok None
    | Some raw ->
      (match int_of_string_opt (String.trim raw) with
       | Some n when n > 0 ->
         Ok (Some (Attachment_store.quantize_thumb_px n))
       | Some _ | None ->
         Error (Printf.sprintf "invalid max_px %S (expected positive integer)" raw))
  in
  match format_res, max_px_res with
  | Ok target_format, Ok max_px -> Ok { download; target_format; max_px }
  | Error msg, _ | _, Error msg -> Error msg
;;

let etag_for_query ~(meta : Attachment_store.meta) (q : fetch_query) =
  match q.target_format, q.max_px with
  | Attachment_store.Native_format, None -> meta.sha256
  | Attachment_store.Force_png, None -> meta.sha256 ^ "-png"
  | Attachment_store.Native_format, Some px -> Printf.sprintf "%s-max%d" meta.sha256 px
  | Attachment_store.Force_png, Some px -> Printf.sprintf "%s-max%d-png" meta.sha256 px
;;

let respond_get_error request reqd err =
  match err with
  | Attachment_store.Invalid_id _ ->
    respond_err
      ~status:`Bad_request
      ~code:"invalid_id"
      ~message:(Attachment_store.get_error_to_string err)
      request
      reqd
  | Attachment_store.Integrity_mismatch _
  | Attachment_store.Corrupt_metadata _
  | Attachment_store.Read_failed _ ->
    Log.Misc.error "attachment read failed: %s" (Attachment_store.get_error_to_string err);
    respond_err
      ~status:`Service_unavailable
      ~code:"attachment_unreadable"
      ~message:"attachment unreadable"
      request
      reqd
;;

let authorize_http_read_meta ~base_path ~store ~(meta : Attachment_store.meta) request =
  match meta.retention with
  | Attachment_store.Durable -> true
  | Attachment_store.Ephemeral _ ->
    Eio_unix.run_in_systhread (fun () ->
      let auth_cfg = Auth.load_auth_config base_path in
      let token = Server_auth.auth_token_from_request request in
      let internal_keeper_agent = Http.Request.header request "x-masc-keeper-name" in
      match Auth.admit_request base_path ~auth_cfg ~token ~internal_keeper_agent with
      | Ok Auth.Auth_off | Ok Auth.Anonymous -> true
      | Ok (Auth.Bearer { role = Masc_domain.Admin; _ }) -> true
      | Ok (Auth.Bearer { agent_name; role = Masc_domain.Worker | Masc_domain.Player; _ }) ->
        Attachment_store.has_ephemeral_pin store ~keeper:agent_name ~sha256:meta.sha256
      | Error _ -> false)
;;

let respond_forbidden_ephemeral request reqd =
  respond_err
    ~status:`Forbidden
    ~code:"forbidden_ephemeral_scope"
    ~message:"ephemeral attachment belongs to another keeper"
    request
    reqd
;;

let systhread_blocking : Attachment_store.blocking_runner =
  { Attachment_store.run_blocking = (fun f -> Eio_unix.run_in_systhread f) }
;;

let serve_loaded_meta ~base_path ~store ~(meta : Attachment_store.meta) ~query request reqd =
  if not (authorize_http_read_meta ~base_path ~store ~meta request)
  then respond_forbidden_ephemeral request reqd
  else (
    let etag = etag_for_query ~meta query in
    if Http.Response.request_holds_tag ~etag request
    then Http.Response.not_modified ~headers:(not_modified_headers ~etag request) reqd
    else (
      let opaque = Attachment_store.is_opaque_binary meta in
      let force_download = query.download || opaque in
      let disposition = content_disposition_of ~download:force_download ~meta in
      let headers = attachment_security_headers ~etag ~disposition request in
      let raw_res =
        Eio_unix.run_in_systhread (fun () ->
          Attachment_store.get_bytes_by_sha256 store ~sha256:meta.sha256)
      in
      match raw_res with
      | Error err -> respond_get_error request reqd err
      | Ok None ->
        respond_err
          ~status:`Not_found
          ~code:"not_found"
          ~message:"attachment blob not found"
          request
          reqd
      | Ok (Some raw_bytes) ->
        (match query.target_format, query.max_px with
         | Attachment_store.Native_format, None ->
           let content_type =
             if opaque then "application/octet-stream" else meta.mime_type
           in
           Http.Response.bytes ~content_type ~headers raw_bytes reqd
         | (Attachment_store.Force_png as target_format), max_px
         | (Attachment_store.Native_format as target_format), (Some _ as max_px) ->
           (* Disk I/O (cache checks, temp files, thumb save) is offloaded via
              [systhread_blocking], while [Process_eio] runs directly on this
              Eio fiber so [Eio.Switch.run] succeeds once [Process_eio.init] is
              active. *)
           let deriv_res =
             Attachment_store.get_image_derivative
               ~blocking:systhread_blocking
               ?max_px
               ~target_format
               store
               ~meta
               ~raw_bytes
           in
           (match deriv_res with
            | Ok (out_mime, out_bytes) ->
              Http.Response.bytes ~content_type:out_mime ~headers out_bytes reqd
            | Error (Attachment_store.Not_an_image _ as err) ->
              respond_err
                ~status:(`Code 422)
                ~code:"not_an_image"
                ~message:(Attachment_store.derivative_error_to_string err)
                request
                reqd
            | Error (Attachment_store.Invalid_max_px _ as err) ->
              respond_err
                ~status:`Bad_request
                ~code:"invalid_max_px"
                ~message:(Attachment_store.derivative_error_to_string err)
                request
                reqd
            | Error (Attachment_store.Transform_failed _ as err) ->
              Log.Misc.error
                "attachment transform failed id=%s: %s"
                meta.id
                (Attachment_store.derivative_error_to_string err);
              respond_err
                ~status:`Internal_server_error
                ~code:"transform_failed"
                ~message:"image transform failed"
                request
                reqd))))
;;

let serve_attachment_by_sha256 ~base_path ~sha256 request reqd =
  let store = Attachment_store.create ~base_path in
  let meta_res =
    Eio_unix.run_in_systhread (fun () ->
      Attachment_store.get_meta_by_sha256 store ~sha256)
  in
  match meta_res with
  | Ok None -> false
  | Error err ->
    respond_get_error request reqd err;
    true
  | Ok (Some meta) ->
    (match parse_fetch_query request with
     | Error msg ->
       respond_err ~status:`Bad_request ~code:"invalid_query" ~message:msg request reqd;
       true
     | Ok query ->
       serve_loaded_meta ~base_path ~store ~meta ~query request reqd;
       true)
;;

let handle_get_subpath state request reqd =
  let base_path = (Mcp_server.workspace_config state).base_path in
  let path = Http.Request.path request in
  match extract_path_param ~prefix:Attachment_store.url_prefix path with
  | None ->
    respond_err
      ~status:`Bad_request
      ~code:"missing_id"
      ~message:"attachment id required"
      request
      reqd
  | Some suffix ->
    (match String.split_on_char '/' suffix with
     | [ raw_id; "meta" ] ->
       (match Attachment_store.parse_id raw_id with
        | Error msg ->
          respond_err ~status:`Bad_request ~code:"invalid_id" ~message:msg request reqd
        | Ok sha256 ->
          let store = Attachment_store.create ~base_path in
          let meta_res =
            Eio_unix.run_in_systhread (fun () ->
              Attachment_store.get_meta_by_sha256 store ~sha256)
          in
          (match meta_res with
           | Error err -> respond_get_error request reqd err
           | Ok None ->
             respond_err
               ~status:`Not_found
               ~code:"not_found"
               ~message:"attachment not found"
               request
               reqd
           | Ok (Some meta) ->
             if not (authorize_http_read_meta ~base_path ~store ~meta request)
             then respond_forbidden_ephemeral request reqd
             else
               respond_json_value_with_cors
                 ~status:`OK
                 request
                 reqd
                 (`Assoc
                    [ "ok", `Bool true
                    ; "data", Attachment_store.meta_to_wire_json meta
                    ])))
     | [ raw_id ] ->
       (match Attachment_store.parse_id raw_id with
        | Error msg ->
          respond_err ~status:`Bad_request ~code:"invalid_id" ~message:msg request reqd
        | Ok sha256 ->
          (match parse_fetch_query request with
           | Error msg ->
             respond_err ~status:`Bad_request ~code:"invalid_query" ~message:msg request reqd
           | Ok query ->
             let store = Attachment_store.create ~base_path in
             let meta_res =
               Eio_unix.run_in_systhread (fun () ->
                 Attachment_store.get_meta_by_sha256 store ~sha256)
             in
             (match meta_res with
              | Error err -> respond_get_error request reqd err
              | Ok None ->
                respond_err
                  ~status:`Not_found
                  ~code:"not_found"
                  ~message:"attachment not found"
                  request
                  reqd
              | Ok (Some meta) ->
                serve_loaded_meta ~base_path ~store ~meta ~query request reqd)))
     | _ ->
       respond_err
         ~status:`Not_found
         ~code:"not_found"
         ~message:"unknown attachment route"
         request
         reqd)
;;

let add_routes router =
  router
  |> Server_route.post
       (Server_route.Permission upload_permission)
       "/api/v1/attachments"
       handle_upload
  |> Server_route.prefix_get
       (Server_route.Permission read_permission)
       Attachment_store.url_prefix
       handle_get_subpath
;;
