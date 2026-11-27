(** Workspace media HTTP surface ([GET /api/v1/media/<sha256>] and
    [POST /api/v1/media]). *)

module Http = Http_server_eio
module Store = Keeper_chat_media_store

type upload_refusal =
  | Empty_upload
  | Truncated_upload of
      { declared : int
      ; received : int
      }
  | Upload_too_large of
      { max_bytes : int
      ; size_bytes : int option
      }
  | Svg_not_allowed
  | Unsupported_media_type of
      { declared : string option
      ; sniffed : Store.raster_mime option
      }
  | Mime_mismatch of
      { declared : Store.raster_mime
      ; sniffed : Store.raster_mime
      }
  | Media_store_failed

let immutable_cache_control = "private, max-age=31536000, immutable"
let no_store_cache_control = "no-store"
let media_csp = "default-src 'none'; sandbox"
let nosniff_header = "x-content-type-options", "nosniff"

let content_disposition_of_media ~sha256 mime =
  let filename = sha256 ^ "." ^ Store.ext_of_media_mime mime in
  match mime with
  | Store.Raster _
  | Store.Audio_mpeg
  | Store.Audio_wav
  | Store.Audio_ogg
  | Store.Audio_midi -> Printf.sprintf "inline; filename=\"%s\"" filename
  | Store.Application_pdf -> Printf.sprintf "attachment; filename=\"%s\"" filename
;;

let media_validator_headers ~cors ~sha256 ~mime =
  let has_origin_vary =
    List.exists
      (fun (name, (_ : string)) -> String.equal (String.lowercase_ascii name) "vary")
      cors
  in
  let cors_without_vary =
    List.filter
      (fun (name, (_ : string)) ->
         not (String.equal (String.lowercase_ascii name) "vary"))
      cors
  in
  let vary_value =
    if has_origin_vary
    then "Origin, Authorization, Cookie"
    else "Authorization, Cookie"
  in
  [ "etag", "\"" ^ sha256 ^ "\""
  ; "cache-control", immutable_cache_control
  ; nosniff_header
  ; "content-security-policy", media_csp
  ; "content-disposition", content_disposition_of_media ~sha256 mime
  ; "vary", vary_value
  ]
  @ cors_without_vary
;;

let respond_no_store_json ~cors ~status ~request reqd json =
  Http.Response.json_value
    ~status
    ~compress:false
    ~request
    ~extra_headers:(("cache-control", no_store_cache_control) :: cors)
    json
    reqd
;;

let stored_media_to_json (stored : Store.stored_media) =
  let width_json, height_json =
    match stored.Store.dimensions with
    | Some { Store.width; height } -> `Int width, `Int height
    | None -> `Null, `Null
  in
  `Assoc
    [ "path", `String stored.Store.path
    ; "sha256", `String stored.Store.sha256
    ; "mime", `String (Store.raster_mime_to_string stored.Store.mime)
    ; "bytes", `Int stored.Store.bytes
    ; "width", width_json
    ; "height", height_json
    ]
;;

let upload_refusal_response = function
  | Empty_upload ->
    `Assoc [ "error", `String "empty upload"; "code", `String "empty_upload" ], `Bad_request
  | Truncated_upload { declared; received } ->
    ( `Assoc
        [ "error", `String "upload ended before its Content-Length"
        ; "code", `String "truncated_upload"
        ; "declared_bytes", `Int declared
        ; "received_bytes", `Int received
        ]
    , `Bad_request )
  | Upload_too_large { max_bytes; size_bytes } ->
    let base =
      [ "error", `String "media too large"
      ; "code", `String "media_too_large"
      ; "max_bytes", `Int max_bytes
      ]
    in
    let fields =
      match size_bytes with
      | Some actual -> base @ [ "size_bytes", `Int actual ]
      | None -> base
    in
    `Assoc fields, `Payload_too_large
  | Svg_not_allowed ->
    ( `Assoc
        [ "error", `String "SVG uploads are not allowed; use raster images (PNG, JPEG, GIF, WebP)"
        ; "code", `String "svg_not_allowed"
        ]
    , `Unsupported_media_type )
  | Unsupported_media_type { declared; sniffed } ->
    let base =
      [ ( "error"
        , `String
            "unsupported media type; expected image/png, image/jpeg, image/gif, or image/webp" )
      ; "code", `String "unsupported_media_type"
      ]
    in
    let fields =
      match declared with
      | Some value -> base @ [ "declared_mime", `String value ]
      | None -> base
    in
    let fields =
      match sniffed with
      | Some mime -> fields @ [ "detected_mime", `String (Store.raster_mime_to_string mime) ]
      | None -> fields
    in
    `Assoc fields, `Unsupported_media_type
  | Mime_mismatch { declared; sniffed } ->
    ( `Assoc
        [ "error", `String "declared Content-Type does not match payload magic bytes"
        ; "code", `String "mime_mismatch"
        ; "declared_mime", `String (Store.raster_mime_to_string declared)
        ; "detected_mime", `String (Store.raster_mime_to_string sniffed)
        ]
    , `Unsupported_media_type )
  | Media_store_failed ->
    ( `Assoc
        [ "error", `String "media upload failed"
        ; "code", `String "media_store_failed"
        ]
    , `Internal_server_error )
;;

let store_upload ~base_path ~content_type ~declared ~bytes =
  let received = String.length bytes in
  match declared with
  | Some declared when declared <> received ->
    Error (Truncated_upload { declared; received })
  | Some _ | None ->
    (match Store.persist_raster_upload ~base_dir:base_path ~content_type ~data:bytes with
     | Ok stored -> Ok stored
     | Error Store.Upload_empty -> Error Empty_upload
     | Error (Store.Upload_too_large { size_bytes; max_bytes }) ->
       Error (Upload_too_large { max_bytes; size_bytes = Some size_bytes })
     | Error Store.Upload_svg_not_allowed -> Error Svg_not_allowed
     | Error (Store.Upload_unsupported_media_type { declared; sniffed }) ->
       Error (Unsupported_media_type { declared; sniffed })
     | Error (Store.Upload_mime_mismatch { declared; sniffed }) ->
       Error (Mime_mismatch { declared; sniffed })
     | Error (Store.Upload_write_failed detail) ->
       Log.Misc.error "workspace media upload store failed: %s" detail;
       Error Media_store_failed)
;;

let handle_get ~cors ~base_path request reqd =
  let path = Http.Request.path request in
  match Server_utils.extract_path_param ~prefix:Masc_network_defaults.media_path_prefix path with
  | None ->
    respond_no_store_json
      ~cors
      ~status:`Bad_request
      ~request
      reqd
      (`Assoc
         [ "error", `String "token path parameter required"
         ; "code", `String "invalid_token"
         ])
  | Some raw when not (Store.valid_token raw) ->
    respond_no_store_json
      ~cors
      ~status:`Bad_request
      ~request
      reqd
      (`Assoc
         [ "error", `String "invalid token"
         ; "code", `String "invalid_token"
         ; "reason", `String "expected 64-char lowercase hex (SHA-256)"
         ])
  | Some token ->
    (match Store.resolve_token ~base_dir:base_path ~token with
     | None ->
       respond_no_store_json
         ~cors
         ~status:`Not_found
         ~request
         reqd
         (`Assoc
            [ "error", `String "not found"
            ; "code", `String "not_found"
            ; "token", `String token
            ])
     | Some (file_path, mime) ->
       let max_bytes = Store.max_raw_bytes () in
       (match Fs_compat.file_size file_path with
        | None ->
          respond_no_store_json
            ~cors
            ~status:`Not_found
            ~request
            reqd
            (`Assoc
               [ "error", `String "not found"
               ; "code", `String "not_found"
               ; "token", `String token
               ])
        | Some size when size > max_bytes ->
          respond_no_store_json
            ~cors
            ~status:`Payload_too_large
            ~request
            reqd
            (`Assoc
               [ "error", `String "media too large"
               ; "code", `String "media_too_large"
               ; "token", `String token
               ; "max_bytes", `Int max_bytes
               ; "size_bytes", `Int size
               ])
        | Some _ ->
          let headers = media_validator_headers ~cors ~sha256:token ~mime in
          if Http.Response.request_holds_tag ~etag:token request
          then Http.Response.not_modified ~headers reqd
          else (
            match Fs_compat.load_file_opt file_path with
            | None ->
              respond_no_store_json
                ~cors
                ~status:`Not_found
                ~request
                reqd
                (`Assoc
                   [ "error", `String "not found"
                   ; "code", `String "not_found"
                   ; "token", `String token
                   ])
            | Some body ->
              Http.Response.bytes
                ~content_type:(Store.media_mime_to_string mime)
                ~headers
                body
                reqd)))
;;

let handle_upload ~cors ~base_path ~actor request reqd =
  let max_bytes = Store.max_raw_bytes () in
  let content_type = Http.Request.header request "content-type" in
  let declared =
    Option.bind (Http.Request.header request "content-length") (fun raw ->
      int_of_string_opt (String.trim raw))
  in
  let refuse refusal =
    let json, status = upload_refusal_response refusal in
    respond_no_store_json ~cors ~status ~request reqd json
  in
  Http.Request.read_body_async_with_limit
    reqd
    ~max_bytes
    ~on_body:(fun bytes ->
      match
        Eio_guard.run_in_systhread ~label:"workspace-media-store" (fun () ->
          store_upload ~base_path ~content_type ~declared ~bytes)
      with
      | Error refusal -> refuse refusal
      | Ok stored ->
        Log.Misc.info
          "workspace media upload by %s: %s (%s, %d bytes)"
          actor
          stored.Store.sha256
          (Store.raster_mime_to_string stored.Store.mime)
          stored.Store.bytes;
        respond_no_store_json
          ~cors
          ~status:`Created
          ~request
          reqd
          (stored_media_to_json stored))
    ~on_error:(function
      | Http.Request.Too_large max_bytes ->
        refuse (Upload_too_large { max_bytes; size_bytes = declared })
      | Http.Request.Internal exn ->
        Log.Misc.error
          "workspace media upload body read failed: %s"
          (Printexc.to_string exn);
        refuse Media_store_failed)
;;

let add_routes router =
  router
  |> Server_route.prefix_get
       (Server_route.Permission Masc_domain.CanReadState)
       Masc_network_defaults.media_path_prefix
       (fun state request reqd ->
          let base_path = (Mcp_server.workspace_config state).base_path in
          let cors = Server_auth.admitted_cors_headers request in
          handle_get ~cors ~base_path request reqd)
  |> Server_route.post
       (Server_route.Token_permission Masc_domain.CanAdmin)
       Masc_network_defaults.media_upload_path
       (fun state agent_name request reqd ->
          let base_path = (Mcp_server.workspace_config state).base_path in
          let cors = Server_auth.admitted_cors_headers request in
          handle_upload ~cors ~base_path ~actor:agent_name request reqd)
;;
