(* RFC-0203 Phase 2 — Discord REST send_message.

   Thin wrapper over Masc_http_client.post_sync. Splits into pure
   build_request and parse_response helpers so the wire-format
   contract can be unit-tested without a network round trip. *)

type error =
  | Network of string
  | Http_status of { code : int; body : string }
  | Discord_api of { code : int; message : string }
  | Other of string

let pp_error fmt = function
  | Network msg -> Format.fprintf fmt "network: %s" msg
  | Http_status { code; body } ->
      Format.fprintf fmt "http %d: %s" code body
  | Discord_api { code; message } ->
      Format.fprintf fmt "discord %d: %s" code message
  | Other msg -> Format.fprintf fmt "other: %s" msg

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
  "DiscordBot (https://github.com/jeong-sik/masc, 0.1)"

let auth_headers ~token =
  [ "Authorization", "Bot " ^ token
  ; "User-Agent", user_agent
  ]

let build_request ~token ~channel_id ~content ?reply_to_message_id () =
  let url =
    Printf.sprintf
      "%s/channels/%s/messages"
      api_base channel_id
  in
  let headers =
    ("Content-Type", "application/json") :: auth_headers ~token
  in
  let fields = [ "content", `String content ] in
  let fields =
    match reply_to_message_id with
    | None -> fields
    | Some ref_id ->
        ("message_reference", `Assoc [ "message_id", `String ref_id ])
        :: fields
  in
  let body = Yojson.Safe.to_string (`Assoc fields) in
  (url, headers, body)

let build_typing_request ~token ~channel_id () =
  let url =
    Printf.sprintf
      "%s/channels/%s/typing"
      api_base channel_id
  in
  (url, auth_headers ~token, "")

let build_channel_request ~token ~channel_id () =
  let url = Printf.sprintf "%s/channels/%s" api_base channel_id in
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
  let url = Printf.sprintf "%s/channels/%s/messages" api_base channel_id in
  let params =
    (match limit with Some value -> [ "limit", string_of_int value ] | None -> [])
    @ (match before with Some value -> [ "before", value ] | None -> [])
    @ (match after with Some value -> [ "after", value ] | None -> [])
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
  let url = Printf.sprintf "%s/guilds/%s/%s" api_base guild_id path in
  let params =
    (match query with
     | Some value when String.trim value <> "" -> [ "query", value ]
     | Some _ | None -> [])
    @ (match limit with Some value -> [ "limit", string_of_int value ] | None -> [])
    @ (match query with
       | Some value when String.trim value <> "" -> []
       | Some _ | None ->
         (match after with Some value -> [ "after", value ] | None -> []))
  in
  (add_query_params url params, auth_headers ~token, "")

let build_guild_member_request ~token ~guild_id ~user_id () =
  let url = Printf.sprintf "%s/guilds/%s/members/%s" api_base guild_id user_id in
  (url, auth_headers ~token, "")

let parse_json_safe s =
  try Some (Yojson.Safe.from_string s) with Yojson.Json_error _ -> None

let field_opt name = function
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None

let error_of_non2xx ~status ~body =
  match parse_json_safe body with
  | None -> Http_status { code = status; body }
  | Some json ->
      let code =
        match field_opt "code" json with
        | Some (`Int c) -> c
        | _ -> status
      in
      let message =
        match field_opt "message" json with
        | Some (`String s) -> s
        | _ -> body
      in
      Discord_api { code; message }

let parse_response ~status ~body =
  if status >= 200 && status < 300 then
    match parse_json_safe body with
    | None ->
        Error (Other ("2xx response body is not valid JSON: " ^ body))
    | Some json ->
        (match field_opt "id" json with
         | Some (`String id) -> Ok id
         | _ -> Error (Other "2xx response missing 'id' string"))
  else
    Error (error_of_non2xx ~status ~body)

let parse_json_response ~status ~body =
  if status >= 200 && status < 300 then
    match parse_json_safe body with
    | Some json -> Ok json
    | None -> Error (Other ("2xx response body is not valid JSON: " ^ body))
  else
    Error (error_of_non2xx ~status ~body)

let parse_empty_response ~status ~body =
  if status >= 200 && status < 300 then Ok ()
  else Error (error_of_non2xx ~status ~body)

let send_message ?clock ?(timeout_sec = Masc_http_client.default_request_timeout_sec)
    ~token ~channel_id ~content ?reply_to_message_id () =
  let (url, headers, body) =
    build_request ~token ~channel_id ~content ?reply_to_message_id ()
  in
  match Masc_http_client.post_sync ?clock ~timeout_sec ~url ~headers ~body () with
  | Error msg -> Error (Network msg)
  | Ok (status, body) -> parse_response ~status ~body

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
      api_base channel_id message_id
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
  let (url, headers, body) =
    build_edit_request ~token ~channel_id ~message_id ~content ()
  in
  match Masc_http_client.patch_sync ?clock ~timeout_sec ~url ~headers ~body () with
  | Error msg -> Error (Network msg)
  | Ok (status, body) -> parse_empty_response ~status ~body

let trigger_typing ?clock ?(timeout_sec = Masc_http_client.default_request_timeout_sec)
    ~token ~channel_id () =
  let url, headers, body = build_typing_request ~token ~channel_id () in
  match Masc_http_client.post_sync ?clock ~timeout_sec ~url ~headers ~body () with
  | Error msg -> Error (Network msg)
  | Ok (status, body) -> parse_empty_response ~status ~body

let get_json ?clock ?(timeout_sec = Masc_http_client.default_request_timeout_sec)
    ~url ~headers () =
  match Masc_http_client.get_sync ?clock ~timeout_sec ~url ~headers () with
  | Error msg -> Error (Network msg)
  | Ok (status, body) -> parse_json_response ~status ~body

let get_channel ?clock ?timeout_sec ~token ~channel_id () =
  let url, headers, _ = build_channel_request ~token ~channel_id () in
  get_json ?clock ?timeout_sec ~url ~headers ()

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
  get_json ?clock ?timeout_sec ~url ~headers ()

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
  get_json ?clock ?timeout_sec ~url ~headers ()

let get_guild_member ?clock ?timeout_sec ~token ~guild_id ~user_id () =
  let url, headers, _ = build_guild_member_request ~token ~guild_id ~user_id () in
  get_json ?clock ?timeout_sec ~url ~headers ()

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
      api_base channel_id
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
      api_base channel_id message_id
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
  let (url, headers, body) =
    build_embed_request ~token ~channel_id ~content ?embeds ()
  in
  match Masc_http_client.post_sync ?clock ~timeout_sec ~url ~headers ~body () with
  | Error msg -> Error (Network msg)
  | Ok (status, body) -> parse_response ~status ~body
