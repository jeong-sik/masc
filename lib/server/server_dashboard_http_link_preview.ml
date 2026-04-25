open Yojson.Safe.Util

type preview_extract = {
  title : string option;
  description : string option;
  site_name : string option;
  image_url : string option;
  canonical_url : string option;
  favicon_url : string option;
}

type cache_payload = {
  preview : Yojson.Safe.t;
  expires_at : float;
}

let cache_ttl_sec = 3600.0
let error_ttl_sec = 300.0
let max_preview_urls = 8
let preview_timeout_sec = 5.0
let max_html_chars = 262_144

let preview_cache_mu = Eio.Mutex.create ()
let preview_cache : (string, cache_payload) Hashtbl.t = Hashtbl.create 128

let trim_to_option value =
  let trimmed = String.trim value in
  if trimmed = "" then None else Some trimmed

let lower_trim value = String.lowercase_ascii (String.trim value)

let cache_lookup key =
  Eio.Mutex.use_rw ~protect:true preview_cache_mu (fun () ->
      match Hashtbl.find_opt preview_cache key with
      | Some entry when entry.expires_at > Time_compat.now () -> Some entry.preview
      | Some _ ->
          Hashtbl.remove preview_cache key;
          None
      | None -> None)

let cache_store ~ttl key preview =
  Eio.Mutex.use_rw ~protect:true preview_cache_mu (fun () ->
      Hashtbl.replace preview_cache key
        { preview; expires_at = Time_compat.now () +. ttl })

let json_string_opt_field fields key =
  match List.assoc_opt key fields with
  | Some (`String value) -> trim_to_option value
  | _ -> None

let error_reason_of_json = function
  | `Assoc fields -> json_string_opt_field fields "error"
  | _ -> None

let assoc_upsert fields key value =
  (key, value) :: List.remove_assoc key fields

let with_cache_state preview cache_state =
  match preview with
  | `Assoc fields -> `Assoc (assoc_upsert fields "cache_state" (`String cache_state))
  | _ -> preview

(* Static replacement table — both the entity needles and the
   compiled regexes are fixed.  Old form rebuilt 7 [Re.t] DFAs per
   [decode_html_entities] call; on a meta-rich page [normalize_text]
   fires per [meta_content]/[link_href] hit, so a typical preview
   parse paid dozens of unnecessary compilations. *)
let html_entity_replacements =
  [
    ("&amp;", "&");
    ("&quot;", "\"");
    ("&#39;", "'");
    ("&apos;", "'");
    ("&lt;", "<");
    ("&gt;", ">");
    ("&nbsp;", " ");
  ]
  |> List.map (fun (needle, replacement) ->
       (Re.compile (Re.str needle), replacement))

let decode_html_entities value =
  List.fold_left
    (fun acc (re, replacement) ->
      Re.replace_string re ~all:true ~by:replacement acc)
    value html_entity_replacements

(* Static whitespace-collapse PCRE, hoisted out of the per-call hot
   path that runs once per normalised meta value. *)
let whitespace_collapse_re =
  Re.Pcre.re "[ \t\r\n]+" |> Re.compile

let collapse_whitespace value =
  value
  |> Re.replace_string whitespace_collapse_re ~all:true ~by:" "
  |> String.trim

let normalize_text value =
  value |> decode_html_entities |> collapse_whitespace |> trim_to_option

let is_http_scheme = function
  | Some "http" | Some "https" -> true
  | _ -> false

let is_loopback_or_unspecified_host host =
  Server_auth.is_loopback_host host || Server_auth.is_unspecified_host host

let ipaddr_is_private_or_reserved = function
  | Ipaddr.V4 addr ->
      let octets = Ipaddr.V4.to_octets addr in
      let byte idx = Char.code octets.[idx] in
      let b0 = byte 0 and b1 = byte 1 in
      b0 = 0
      || b0 = 10
      || b0 = 127
      || (b0 = 169 && b1 = 254)
      || (b0 = 172 && b1 >= 16 && b1 <= 31)
      || (b0 = 192 && b1 = 168)
      || (b0 = 100 && b1 >= 64 && b1 <= 127)
      || (b0 = 192 && b1 = 0)
      || (b0 = 198 && (b1 = 18 || b1 = 19))
      || (b0 = 198 && b1 = 51)
      || (b0 = 203 && b1 = 0)
      || b0 >= 224
  | Ipaddr.V6 addr ->
      let text = Ipaddr.V6.to_string addr |> String.lowercase_ascii in
      Ipaddr.V6.compare addr Ipaddr.V6.localhost = 0
      || Ipaddr.V6.compare addr Ipaddr.V6.unspecified = 0
      || String.starts_with ~prefix:"fc" text
      || String.starts_with ~prefix:"fd" text
      || String.starts_with ~prefix:"fe8" text
      || String.starts_with ~prefix:"fe9" text
      || String.starts_with ~prefix:"fea" text
      || String.starts_with ~prefix:"feb" text
      || String.starts_with ~prefix:"ff" text
      || String.starts_with ~prefix:"2001:db8" text

let eio_ipaddr_is_private_or_reserved ip =
  let rendered = Fmt.str "%a" Eio.Net.Ipaddr.pp ip in
  match Ipaddr.of_string rendered with
  | Ok parsed -> ipaddr_is_private_or_reserved parsed
  | Error _ -> true

let validate_resolved_host ~net (uri : Uri.t) =
  try
    match Uri.host uri with
    | None -> Error "missing host"
    | Some host when is_loopback_or_unspecified_host host ->
        Error "host is not allowed"
    | Some host ->
        let service =
          match Uri.port uri with
          | Some port -> Int.to_string port
          | None ->
              if Uri.scheme uri = Some "https" then "443" else "80"
        in
        let addrs = Eio.Net.getaddrinfo_stream ~service net host in
        match addrs with
        | [] -> Error "dns resolution returned no addresses"
        | items ->
            let blocked =
              List.exists
                (function
                  | `Tcp (ip, _) -> eio_ipaddr_is_private_or_reserved ip
                  | `Unix _ -> true)
                items
            in
            if blocked then Error "resolved address is not allowed" else Ok ()
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn -> Error (Printf.sprintf "dns failure: %s" (Printexc.to_string exn))

let normalize_request_url raw =
  let trimmed = String.trim raw in
  if trimmed = "" then Error "url is empty"
  else
    let uri = Uri.of_string trimmed in
    if not (is_http_scheme (Uri.scheme uri)) then
      Error "only http/https URLs are allowed"
    else if Uri.userinfo uri <> None then
      Error "userinfo in URL is not allowed"
    else if Uri.host uri = None then
      Error "missing host"
    else
      Ok (Uri.with_fragment uri None |> Uri.to_string)

let image_extensions =
  [ ".png"; ".jpg"; ".jpeg"; ".gif"; ".webp"; ".svg"; ".avif"; ".bmp" ]

let infer_image_url url =
  let lower = String.lowercase_ascii url in
  List.exists (fun ext -> Filename.check_suffix lower ext) image_extensions

(* Static [<head>...</head>] extractor — every link-preview parse hit
   the per-call [Re.compile] before this hoist. *)
let head_fragment_re =
  Re.Pcre.re ~flags:[ `CASELESS; `DOTALL ] "<head[^>]*>(.*?)</head>"
  |> Re.compile

let first_head_fragment body =
  match Re.exec_opt head_fragment_re body with
  | Some groups -> Re.Group.get groups 1
  | None -> String.sub body 0 (min (String.length body) max_html_chars)

let first_match body pattern =
  let re =
    Re.Pcre.re ~flags:[ `CASELESS; `DOTALL ] pattern |> Re.compile
  in
  match Re.exec_opt re body with
  | Some groups -> normalize_text (Re.Group.get groups 1)
  | None -> None

let meta_content head attr key =
  let quoted value =
    Printf.sprintf
      "<meta[^>]+%s\\s*=\\s*['\"]%s['\"][^>]+content\\s*=\\s*['\"]([^'\"]+)['\"][^>]*>"
      attr value
  in
  let reversed value =
    Printf.sprintf
      "<meta[^>]+content\\s*=\\s*['\"]([^'\"]+)['\"][^>]+%s\\s*=\\s*['\"]%s['\"][^>]*>"
      attr value
  in
  match first_match head (quoted key) with
  | Some _ as value -> value
  | None -> first_match head (reversed key)

let link_href head rel_value =
  let pattern =
    Printf.sprintf
      "<link[^>]+rel\\s*=\\s*['\"][^'\"]*%s[^'\"]*['\"][^>]+href\\s*=\\s*['\"]([^'\"]+)['\"][^>]*>"
      rel_value
  in
  let reversed =
    Printf.sprintf
      "<link[^>]+href\\s*=\\s*['\"]([^'\"]+)['\"][^>]+rel\\s*=\\s*['\"][^'\"]*%s[^'\"]*['\"][^>]*>"
      rel_value
  in
  match first_match head pattern with
  | Some _ as value -> value
  | None -> first_match head reversed

let title_tag head =
  first_match head "<title[^>]*>(.*?)</title>"

let resolve_relative_url ~base_url value =
  let base_uri = Uri.of_string base_url in
  Uri.resolve "" base_uri (Uri.of_string value) |> Uri.to_string

let default_favicon_url url =
  let uri = Uri.of_string url in
  Uri.make ?scheme:(Uri.scheme uri) ?host:(Uri.host uri) ?port:(Uri.port uri)
    ~path:"/favicon.ico" ()
  |> Uri.to_string

let extract_html_preview_fields ~url body =
  let head = first_head_fragment body in
  let title =
    match meta_content head "property" "og:title" with
    | Some _ as value -> value
    | None -> (
        match meta_content head "name" "twitter:title" with
        | Some _ as value -> value
        | None -> title_tag head)
  in
  let description =
    match meta_content head "property" "og:description" with
    | Some _ as value -> value
    | None -> (
        match meta_content head "name" "twitter:description" with
        | Some _ as value -> value
        | None -> meta_content head "name" "description")
  in
  let site_name =
    match meta_content head "property" "og:site_name" with
    | Some _ as value -> value
    | None -> Uri.host (Uri.of_string url)
  in
  let image_url =
    match meta_content head "property" "og:image" with
    | Some raw -> Some (resolve_relative_url ~base_url:url raw)
    | None -> (
        match meta_content head "name" "twitter:image" with
        | Some raw -> Some (resolve_relative_url ~base_url:url raw)
        | None -> None)
  in
  let canonical_url =
    match link_href head "canonical" with
    | Some raw -> Some (resolve_relative_url ~base_url:url raw)
    | None -> None
  in
  let favicon_url =
    match link_href head "icon" with
    | Some raw -> Some (resolve_relative_url ~base_url:url raw)
    | None -> Some (default_favicon_url url)
  in
  { title; description; site_name; image_url; canonical_url; favicon_url }

let list_header_ci headers name =
  let target = String.lowercase_ascii name in
  headers
  |> List.find_map (fun (key, value) ->
         if String.equal (String.lowercase_ascii key) target then Some value
         else None)

let is_success_status code = code >= 200 && code < 300

let is_redirect_status code =
  code = 301 || code = 302 || code = 303 || code = 307 || code = 308

let https_connector_result () =
  match Eio_context.get_https_connector_result () with
  | Ok connector -> Ok (Some connector)
  | Error message -> Error message

let fetch_response ~net ~url =
  let uri = Uri.of_string url in
  let https_result =
    if Uri.scheme uri = Some "https" then https_connector_result () else Ok None
  in
  match https_result with
  | Error _ as error -> error
  | Ok https ->
      Masc_http_client.get_response_sync ~net ~https ~url
        ~headers:
          [
            ("Accept", "text/html,application/xhtml+xml,image/*;q=0.9,*/*;q=0.1");
            ("Accept-Encoding", "identity");
            ("User-Agent", "MASC-Dashboard-LinkPreview/1.0");
          ]
        ()

let rec fetch_response_following_redirects ~net ~url ~remaining_redirects =
  match fetch_response ~net ~url with
  | Error _ as error -> error
  | Ok response when is_redirect_status response.status && remaining_redirects > 0
    ->
      (match list_header_ci response.headers "location" with
       | Some location when String.trim location <> "" ->
           let next_url = resolve_relative_url ~base_url:url location in
           fetch_response_following_redirects ~net ~url:next_url
             ~remaining_redirects:(remaining_redirects - 1)
       | _ -> Ok response)
  | Ok response -> Ok response

let build_preview_json ~url ~kind ?canonical_url ?title ?description ?site_name
    ?image_url ?favicon_url ?content_type ~cache_state () =
  let fields =
    [
      ("url", `String url);
      ("kind", `String kind);
      ("canonical_url", Json_util.string_opt_to_json canonical_url);
      ("title", Json_util.string_opt_to_json title);
      ("description", Json_util.string_opt_to_json description);
      ("site_name", Json_util.string_opt_to_json site_name);
      ("image_url", Json_util.string_opt_to_json image_url);
      ("favicon_url", Json_util.string_opt_to_json favicon_url);
      ("content_type", Json_util.string_opt_to_json content_type);
      ("fetched_at", `String (Types.now_iso ()));
      ("cache_state", `String cache_state);
    ]
  in
  `Assoc fields

let error_json ~url ~reason ~cache_state () =
  `Assoc
    [
      ("url", `String url);
      ("error", `String reason);
      ("cache_state", `String cache_state);
    ]

let fetch_preview ~clock ~net url =
  match normalize_request_url url with
  | Error reason -> Error reason
  | Ok normalized_url -> (
      match validate_resolved_host ~net (Uri.of_string normalized_url) with
      | Error reason -> Error reason
      | Ok () ->
          if infer_image_url normalized_url then
            Ok
              (build_preview_json ~url:normalized_url ~kind:"image"
                 ~image_url:normalized_url
                 ~favicon_url:(default_favicon_url normalized_url)
                 ~cache_state:"miss" ())
          else
            let run () =
              match
                fetch_response_following_redirects ~net ~url:normalized_url
                  ~remaining_redirects:2
              with
              | Error message -> Error message
              | Ok response ->
                  if not (is_success_status response.status) then
                    Error (Printf.sprintf "HTTP %d" response.status)
                  else
                    let content_type = list_header_ci response.headers "content-type" in
                    if
                      Option.value ~default:false
                        (Option.map
                           (fun value ->
                             match String.split_on_char ';' value with
                             | head :: _ ->
                                 String.starts_with ~prefix:"image/"
                                   (lower_trim head)
                             | [] -> false)
                           content_type)
                    then
                      Ok
                        (build_preview_json ~url:normalized_url ~kind:"image"
                           ~image_url:normalized_url
                           ?content_type
                           ~favicon_url:(default_favicon_url normalized_url)
                           ~cache_state:"miss" ())
                    else
                      let body =
                        if String.length response.body > max_html_chars then
                          String.sub response.body 0 max_html_chars
                        else response.body
                      in
                      let extracted =
                        extract_html_preview_fields ~url:normalized_url body
                      in
                      let canonical_url =
                        match extracted.canonical_url with
                        | Some value -> Some value
                        | None -> Some normalized_url
                      in
                      Ok
                        (build_preview_json ~url:normalized_url ~kind:"link"
                           ?canonical_url
                           ?title:extracted.title
                           ?description:extracted.description
                           ?site_name:extracted.site_name
                           ?image_url:extracted.image_url
                           ?favicon_url:extracted.favicon_url
                           ?content_type
                           ~cache_state:"miss" ())
            in
            try Eio.Time.with_timeout_exn clock preview_timeout_sec run
            with Eio.Cancel.Cancelled _ as e -> raise e
               | exn -> Error (Printexc.to_string exn))

let urls_of_request args =
  match args |> member "urls" with
  | `List items ->
      let urls =
        items
        |> List.filter_map (function
             | `String value ->
                 let trimmed = String.trim value in
                 if trimmed = "" then None else Some trimmed
             | _ -> None)
        |> List.sort_uniq String.compare
      in
      if urls = [] then Error "urls must contain at least one non-empty string"
      else Ok (List.take max_preview_urls urls)
  | _ -> Error "urls must be an array of strings"

let dashboard_link_previews_http_json ~state ~(args : Yojson.Safe.t) :
    (Yojson.Safe.t, string) result =
  let clock_opt =
    match state.Mcp_server.clock with
    | Some _ as clock -> clock
    | None -> Eio_context.get_clock_opt ()
  in
  let net_opt =
    match state.Mcp_server.net with
    | Some _ as net -> net
    | None -> Eio_context.get_net_opt ()
  in
  match clock_opt, net_opt, urls_of_request args with
  | None, _, _ -> Error "dashboard link preview clock unavailable"
  | _, None, _ -> Error "dashboard link preview net unavailable"
  | _, _, (Error _ as error) -> error
  | Some clock, Some net, Ok urls ->
      let preview_fields = ref [] in
      let error_fields = ref [] in
      List.iter
        (fun url ->
          match cache_lookup url with
          | Some cached ->
              (match error_reason_of_json cached with
               | Some reason ->
                   error_fields := (url, `String reason) :: !error_fields
               | None ->
                preview_fields :=
                  (url, with_cache_state cached "hit") :: !preview_fields)
          | None -> (
              match fetch_preview ~clock ~net url with
              | Ok preview ->
                  let persisted = with_cache_state preview "miss" in
                  cache_store ~ttl:cache_ttl_sec url persisted;
                  preview_fields := (url, persisted) :: !preview_fields
              | Error reason ->
                  let error_preview =
                    error_json ~url ~reason ~cache_state:"miss" ()
                  in
                  cache_store ~ttl:error_ttl_sec url error_preview;
                  error_fields := (url, `String reason) :: !error_fields))
        urls;
      Ok
        (`Assoc
          [
            ("previews", `Assoc (List.rev !preview_fields));
            ("errors", `Assoc (List.rev !error_fields));
          ])
