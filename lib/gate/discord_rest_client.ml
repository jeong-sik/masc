(* RFC-0203 Phase 2 — Discord REST send_message.

   Thin wrapper over Masc_http_client.post_sync. Splits into pure
   build_request and parse_response helpers so the wire-format
   contract can be unit-tested without a network round trip. *)

type error =
  | Network of string
  | Http_status of { request_id : string; code : int; body_bytes : int }
  | Discord_api of { request_id : string; code : int }
  | Other of { request_id : string; reason : string; body_bytes : int }

let pp_error fmt = function
  | Network msg -> Format.fprintf fmt "network: %s" msg
  | Http_status { request_id; code; body_bytes } ->
      Format.fprintf fmt "http request=%s status=%d body_bytes=%d"
        request_id code body_bytes
  | Discord_api { request_id; code } ->
      Format.fprintf fmt "discord request=%s code=%d" request_id code
  | Other { request_id; reason; body_bytes } ->
      Format.fprintf fmt "other request=%s reason=%s body_bytes=%d"
        request_id reason body_bytes

let request_sequence = Atomic.make 0

let next_request_id operation =
  let sequence = Atomic.fetch_and_add request_sequence 1 in
  Printf.sprintf "discord-%s-%d" operation sequence

type snowflake = Snowflake of string

let snowflake_of_string value =
  if value = "" || not (String.for_all (fun c -> c >= '0' && c <= '9') value)
  then Error "Discord snowflake must be a non-empty decimal string"
  else Ok (Snowflake value)

let snowflake_to_string (Snowflake value) = value

(* Discord text-message content limit, in Unicode scalar units.
   Messages longer than this must be split into multiple payloads. *)
let message_content_limit = 2000

(* Discord takes the API version in the request path. Built from the
   shared constant so the gateway and REST surfaces cannot drift apart. *)
let api_base =
  Printf.sprintf "https://discord.com/api/v%d" Discord_api_version.current

(* Discord requires a specific User-Agent format:
   "DiscordBot ($url, $version)". *)
let user_agent =
  Printf.sprintf
    "DiscordBot (https://github.com/jeong-sik/masc, %s)"
    Build_version.current

let auth_headers ~token =
  [ "Authorization", "Bot " ^ token
  ; "User-Agent", user_agent
  ]

let allowed_mentions_json user_ids =
  match user_ids with
  | [] -> `Assoc [ "parse", `List [] ]
  | user_ids ->
    `Assoc
      [ "users", `List (List.map (fun id -> `String (snowflake_to_string id)) user_ids) ]

let build_request ~token ~channel_id ~content ?reply_to_message_id
    ?(allowed_user_mentions = []) () =
  let url =
    Printf.sprintf
      "%s/channels/%s/messages"
      api_base (snowflake_to_string channel_id)
  in
  let headers =
    ("Content-Type", "application/json") :: auth_headers ~token
  in
  let fields =
    [ "content", `String content
    ; "allowed_mentions", allowed_mentions_json allowed_user_mentions
    ]
  in
  let fields =
    match reply_to_message_id with
    | None -> fields
    | Some ref_id ->
        ( "message_reference"
        , `Assoc
            [ "message_id", `String (snowflake_to_string ref_id) ] )
        :: fields
  in
  let body = Yojson.Safe.to_string (`Assoc fields) in
  (url, headers, body)

let build_typing_request ~token ~channel_id () =
  let url =
    Printf.sprintf
      "%s/channels/%s/typing"
      api_base (snowflake_to_string channel_id)
  in
  (url, auth_headers ~token, "")

let build_channel_request ~token ~channel_id () =
  let url =
    Printf.sprintf "%s/channels/%s" api_base (snowflake_to_string channel_id)
  in
  (url, auth_headers ~token, "")

let build_guild_request ~token ~guild_id () =
  let url =
    Printf.sprintf "%s/guilds/%s" api_base (snowflake_to_string guild_id)
  in
  (url, auth_headers ~token, "")

let build_guild_channels_request ~token ~guild_id () =
  let url =
    Printf.sprintf "%s/guilds/%s/channels" api_base
      (snowflake_to_string guild_id)
  in
  (url, auth_headers ~token, "")

let add_query_params url params =
  Uri.of_string url
  |> fun uri -> Uri.add_query_params' uri params
  |> Uri.to_string

let build_channel_messages_request
      ~token
      ~channel_id
      ?limit
      ?before
      ?after
  ()
  =
  let url =
    Printf.sprintf "%s/channels/%s/messages" api_base
      (snowflake_to_string channel_id)
  in
  let params =
    (match limit with Some value -> [ "limit", string_of_int value ] | None -> [])
    @ (match before with
       | Some value -> [ "before", snowflake_to_string value ]
       | None -> [])
    @ (match after with
       | Some value -> [ "after", snowflake_to_string value ]
       | None -> [])
  in
  (add_query_params url params, auth_headers ~token, "")

let build_guild_members_request
      ~token
      ~guild_id
      ?query
      ?limit
      ?after
      ()
  =
  let path =
    match query with
    | Some value when String.trim value <> "" -> "members/search"
    | Some _ | None -> "members"
  in
  let url =
    Printf.sprintf "%s/guilds/%s/%s" api_base (snowflake_to_string guild_id)
      path
  in
  let params =
    (match query with
     | Some value when String.trim value <> "" -> [ "query", value ]
     | Some _ | None -> [])
    @ (match limit with Some value -> [ "limit", string_of_int value ] | None -> [])
    @ (match query with
       | Some value when String.trim value <> "" -> []
       | Some _ | None ->
         (match after with
          | Some value -> [ "after", snowflake_to_string value ]
          | None -> []))
  in
  (add_query_params url params, auth_headers ~token, "")

let build_guild_member_request ~token ~guild_id ~user_id () =
  let url =
    Printf.sprintf "%s/guilds/%s/members/%s" api_base
      (snowflake_to_string guild_id) (snowflake_to_string user_id)
  in
  (url, auth_headers ~token, "")

let parse_json_safe s =
  Gate_rest_json.parse ~context:"discord_rest_client" s

let error_of_non2xx ~request_id ~status ~body =
  match parse_json_safe body with
  | Error _ ->
    Http_status { request_id; code = status; body_bytes = String.length body }
  | Ok json ->
      let code =
        match Gate_rest_json.int_field "code" json with
        | Some c -> c
        | None -> status
      in
      (match Gate_rest_json.string_field "message" json with
       | Some _ -> Discord_api { request_id; code }
       | None ->
         Http_status
           { request_id; code = status; body_bytes = String.length body })

let parse_response ?request_id ~status ~body () =
  let request_id =
    match request_id with Some value -> value | None -> next_request_id "parse"
  in
  if status >= 200 && status < 300 then
    match parse_json_safe body with
    | Error msg ->
        Error
          (Other
             { request_id
             ; reason = Printf.sprintf "2xx response body rejected: %s" msg
             ; body_bytes = String.length body
             })
    | Ok json ->
        (match Gate_rest_json.string_field "id" json with
         | Some id -> Ok id
         | None ->
           Error
             (Other
                { request_id
                ; reason = "2xx response missing 'id' string"
                ; body_bytes = String.length body
                }))
  else
    Error (error_of_non2xx ~request_id ~status ~body)

let parse_json_response ?request_id ~status ~body () =
  let request_id =
    match request_id with Some value -> value | None -> next_request_id "parse"
  in
  if status >= 200 && status < 300 then
    match parse_json_safe body with
    | Ok json -> Ok (Gate_rest_json.to_yojson json)
    | Error msg ->
      Error
        (Other
           { request_id
           ; reason = Printf.sprintf "2xx response body rejected: %s" msg
           ; body_bytes = String.length body
           })
  else
    Error (error_of_non2xx ~request_id ~status ~body)

let parse_empty_response ?request_id ~status ~body () =
  let request_id =
    match request_id with Some value -> value | None -> next_request_id "parse"
  in
  if status >= 200 && status < 300 then Ok ()
  else Error (error_of_non2xx ~request_id ~status ~body)

let send_message ?clock ?(timeout_sec = Masc_http_client.default_request_timeout_sec)
    ~token ~channel_id ~content ?reply_to_message_id
    ?(allowed_user_mentions = []) () =
  match snowflake_of_string channel_id with
  | Error message -> Error (Network message)
  | Ok channel_id ->
    let rec decode_mentions acc = function
      | [] -> Ok (List.rev acc)
      | value :: rest ->
        (match snowflake_of_string value with
         | Ok id -> decode_mentions (id :: acc) rest
         | Error message -> Error (Network message))
    in
    (match decode_mentions [] allowed_user_mentions with
     | Error _ as error -> error
     | Ok allowed_user_mentions ->
    match reply_to_message_id with
     | Some value ->
       (match snowflake_of_string value with
        | Error message -> Error (Network message)
        | Ok reply_to_message_id ->
          let (url, headers, body) =
            build_request ~token ~channel_id ~content ~reply_to_message_id
              ~allowed_user_mentions ()
          in
          (match
             Masc_http_client.post_sync ?clock ~timeout_sec ~url ~headers ~body
               ()
           with
           | Error msg -> Error (Network msg)
           | Ok (status, body) ->
             parse_response ~request_id:(next_request_id "send") ~status ~body
               ()))
     | None ->
       let (url, headers, body) =
          build_request ~token ~channel_id ~content ~allowed_user_mentions ()
       in
       (match
          Masc_http_client.post_sync ?clock ~timeout_sec ~url ~headers ~body ()
        with
        | Error msg -> Error (Network msg)
        | Ok (status, body) ->
            parse_response ~request_id:(next_request_id "send") ~status ~body
            ()))

(* Byte length of the UTF-8 sequence whose lead byte is [c]. An invalid
   lead byte counts as 1 so iteration always makes progress. *)
let utf8_lead_len c =
  if c land 0x80 = 0 then 1
  else if c land 0xE0 = 0xC0 then 2
  else if c land 0xF0 = 0xE0 then 3
  else if c land 0xF8 = 0xF0 then 4
  else 1

(* Split [s] at the byte offset following its first [limit] Unicode
   scalar values. Returns [(head, tail)] where [head] is a valid-UTF-8
   prefix of at most [limit] codepoints and [tail] is the remainder ([""]
   when [s] already fits). Discord measures message length in Unicode
   scalar units, so cutting on codepoint (not byte) boundaries avoids both
   the 400 rejection a mid-codepoint byte cut produces and the needless
   over-chunking of multi-byte text (e.g. Korean, 3 bytes/char). *)
let split_at_codepoint s ~limit =
  let n = String.length s in
  if limit <= 0 || n = 0 then (s, "")
  else begin
    let rec walk pos cps =
      if pos >= n then (s, "")
      else if cps >= limit then
        (String.sub s 0 pos, String.sub s pos (n - pos))
      else
        let step = min (utf8_lead_len (Char.code s.[pos])) (n - pos) in
        walk (pos + step) (cps + 1)
    in
    walk 0 0
  end

(* Split [s] into a list of chunks each at most [limit] Unicode scalar
   values, every chunk valid UTF-8. Empty input yields [[]]. *)
let chunk_by_codepoint s ~limit =
  let rec loop acc rest =
    if String.length rest = 0 then List.rev acc
    else
      let head, tail = split_at_codepoint rest ~limit in
      if String.length head = 0 then List.rev (rest :: acc)
      else loop (head :: acc) tail
  in
  loop [] s

(* Truncate content to Discord's message_content_limit for PATCH edits,
   on a codepoint boundary so the result is valid UTF-8.
   Discord rejects messages exceeding 2000 Unicode scalar units. *)
let truncate_to_limit content =
  fst (split_at_codepoint content ~limit:message_content_limit)

let build_edit_request ~token ~channel_id ~message_id ~content () =
  let url =
    Printf.sprintf
      "%s/channels/%s/messages/%s"
      api_base (snowflake_to_string channel_id) (snowflake_to_string message_id)
  in
  let headers =
    ("Content-Type", "application/json") :: auth_headers ~token
  in
  let truncated = truncate_to_limit content in
  let body =
    Yojson.Safe.to_string (`Assoc [ "content", `String truncated ])
  in
  (url, headers, body)

let edit_message ?clock ?(timeout_sec = Masc_http_client.default_request_timeout_sec)
    ~token ~channel_id ~message_id ~content () =
  match snowflake_of_string channel_id, snowflake_of_string message_id with
  | Error message, _ | _, Error message -> Error (Network message)
  | Ok channel_id, Ok message_id ->
    let (url, headers, body) =
      build_edit_request ~token ~channel_id ~message_id ~content ()
    in
    match Masc_http_client.patch_sync ?clock ~timeout_sec ~url ~headers ~body () with
    | Error msg -> Error (Network msg)
    | Ok (status, body) ->
      parse_empty_response ~request_id:(next_request_id "edit") ~status ~body ()

let trigger_typing ?clock ?(timeout_sec = Masc_http_client.default_request_timeout_sec)
    ~token ~channel_id () =
  match snowflake_of_string channel_id with
  | Error message -> Error (Network message)
  | Ok channel_id ->
    let url, headers, body = build_typing_request ~token ~channel_id () in
    match Masc_http_client.post_sync ?clock ~timeout_sec ~url ~headers ~body () with
    | Error msg -> Error (Network msg)
    | Ok (status, body) ->
      parse_empty_response ~request_id:(next_request_id "typing") ~status ~body ()

let get_json ?clock ?(timeout_sec = Masc_http_client.default_request_timeout_sec)
    ~request_id ~url ~headers () =
  match Masc_http_client.get_sync ?clock ~timeout_sec ~url ~headers () with
  | Error msg -> Error (Network msg)
  | Ok (status, body) -> parse_json_response ~request_id ~status ~body ()

let get_channel ?clock ?timeout_sec ~token ~channel_id () =
  let url, headers, _ = build_channel_request ~token ~channel_id () in
  get_json ?clock ?timeout_sec ~request_id:(next_request_id "channel") ~url
    ~headers ()

let get_guild ?clock ?timeout_sec ~token ~guild_id () =
  let url, headers, _ = build_guild_request ~token ~guild_id () in
  get_json ?clock ?timeout_sec ~request_id:(next_request_id "guild") ~url
    ~headers ()

let get_guild_channels ?clock ?timeout_sec ~token ~guild_id () =
  let url, headers, _ = build_guild_channels_request ~token ~guild_id () in
  get_json ?clock ?timeout_sec ~request_id:(next_request_id "guild-channels")
    ~url ~headers ()

let get_channel_messages
      ?clock
      ?timeout_sec
      ~token
      ~channel_id
      ?limit
      ?before
      ?after
      ()
  =
  let url, headers, _ =
    build_channel_messages_request ~token ~channel_id ?limit ?before ?after ()
  in
  get_json ?clock ?timeout_sec ~request_id:(next_request_id "messages") ~url
    ~headers ()

let get_guild_members
      ?clock
      ?timeout_sec
      ~token
      ~guild_id
      ?query
      ?limit
      ?after
      ()
  =
  let url, headers, _ =
    build_guild_members_request ~token ~guild_id ?query ?limit ?after ()
  in
  get_json ?clock ?timeout_sec ~request_id:(next_request_id "members") ~url
    ~headers ()

let get_guild_member ?clock ?timeout_sec ~token ~guild_id ~user_id () =
  let url, headers, _ = build_guild_member_request ~token ~guild_id ~user_id () in
  get_json ?clock ?timeout_sec ~request_id:(next_request_id "member") ~url
    ~headers ()

(* ── Embed support ──────────────────────────────────────────────── *)

(* Simplified Discord embed. Only the fields we use for tool
   visualization. Discord enforces: sum of all text fields ≤ 6000
   characters, max 10 embeds per message, embed title ≤ 256 chars. *)
type embed =
  { title : string
  ; description : string option
  ; url : string option
  ; color : int  (* Decimal RGB: 0xRRGGBB *)
  ; image : string option
  ; fields : (string * string * bool) list
    (* (name, value, inline) tuples. Max 25. *)
  }

let embed_to_json (e : embed) : Yojson.Safe.t =
  let base =
    [ ("title", `String e.title)
    ; ("color", `Int e.color)
    ]
  in
  let base =
    match e.description with
    | None -> base
    | Some d -> ("description", `String d) :: base
  in
  let base =
    match e.url with
    | None -> base
    | Some u -> ("url", `String u) :: base
  in
  let base =
    match e.image with
    | None -> base
    | Some i -> ("image", `Assoc [ ("url", `String i) ]) :: base
  in
  let base =
    match e.fields with
    | [] -> base
    | fields ->
        let field_jsons =
          List.map (fun (name, value, inline) ->
            `Assoc
              [ ("name", `String name)
              ; ("value", `String value)
              ; ("inline", `Bool inline)
              ])
            fields
        in
        ("fields", `List field_jsons) :: base
  in
  `Assoc base

(* Embed colors *)
let color_blue = 0x3498DB    (* Running / in progress *)
let color_green = 0x2ECC71   (* Success *)
(* Discord embed field value limit is 1024 characters. *)

let link_embed ~url ~title ~description ~image =
  { title
  ; description
  ; url = Some url
  ; color = color_blue
  ; image
  ; fields = []
  }

let image_embed ~url ~caption =
  { title = "Image"
  ; description = caption
  ; url = None
  ; color = color_green
  ; image = Some url
  ; fields = []
  }

let build_embed_request ~token ~channel_id ~content ?embeds () =
  let url =
    Printf.sprintf
      "%s/channels/%s/messages"
      api_base (snowflake_to_string channel_id)
  in
  let headers =
    ("Content-Type", "application/json") :: auth_headers ~token
  in
  let fields =
    match content with
    | "" | " " -> []
    | c -> [ ("content", `String c) ]
  in
  let fields =
    match embeds with
    | None | Some [] -> fields
    | Some es -> ("embeds", `List (List.map embed_to_json es)) :: fields
  in
  let body = Yojson.Safe.to_string (`Assoc fields) in
  (url, headers, body)

let build_edit_embed_request ~token ~channel_id ~message_id
      ~content ?embeds () =
  let url =
    Printf.sprintf
      "%s/channels/%s/messages/%s"
      api_base (snowflake_to_string channel_id) (snowflake_to_string message_id)
  in
  let headers =
    ("Content-Type", "application/json") :: auth_headers ~token
  in
  let fields =
    match content with
    | "" | " " -> []
    | c -> [ ("content", `String c) ]
  in
  let fields =
    match embeds with
    | None | Some [] -> fields
    | Some es -> ("embeds", `List (List.map embed_to_json es)) :: fields
  in
  let body = Yojson.Safe.to_string (`Assoc fields) in
  (url, headers, body)

let send_embed_message ?clock
    ?(timeout_sec = Masc_http_client.default_request_timeout_sec)
    ~token ~channel_id ~content ?embeds () =
  match snowflake_of_string channel_id with
  | Error message -> Error (Network message)
  | Ok channel_id ->
    let (url, headers, body) =
      build_embed_request ~token ~channel_id ~content ?embeds ()
    in
    match Masc_http_client.post_sync ?clock ~timeout_sec ~url ~headers ~body () with
    | Error msg -> Error (Network msg)
    | Ok (status, body) ->
      parse_response ~request_id:(next_request_id "embed") ~status ~body ()
