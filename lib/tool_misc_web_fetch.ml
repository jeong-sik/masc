module Format = Stdlib.Format
module Map = Stdlib.Map
module Set = Stdlib.Set
module Hashtbl = Stdlib.Hashtbl
module Mutex = Stdlib.Mutex
module Option = Stdlib.Option
module Result = Stdlib.Result
module Sys = Stdlib.Sys
module Filename = Stdlib.Filename
module List = Stdlib.List
module Array = Stdlib.Array
module String = Stdlib.String
module Char = Stdlib.Char
module Int = Stdlib.Int
module Float = Stdlib.Float

open Tool_args

let default_timeout_sec = 15
let default_max_chars = 50_000
let max_chars_cap = 100_000
let max_response_bytes = 2_000_000
let max_redirects = 3

type extract_mode =
  | Markdown
  | Text

type extraction_source =
  | Article
  | Main
  | Body
  | Document
  | Raw_text

let extraction_source_to_string = function
  | Article -> "article"
  | Main -> "main"
  | Body -> "body"
  | Document -> "document"
  | Raw_text -> "raw_text"

type content_kind =
  | Html
  | Plain_text
  | Json_text
  | Xml_text

let content_kind_to_string = function
  | Html -> "html"
  | Plain_text -> "text"
  | Json_text -> "json"
  | Xml_text -> "xml"

let extract_mode_to_string = function
  | Markdown -> "markdown"
  | Text -> "text"

let extract_mode_of_string raw =
  match String.lowercase_ascii (String.trim raw) with
  | "" | "markdown" | "md" -> Some Markdown
  | "text" | "plain" | "plain_text" -> Some Text
  | _ -> None

let default_extract_mode = Markdown

let extract_title html =
  let title =
    Markup_document.parse_html html
    |> Markup_document.first_element_named "title"
    |> Option.map Markup_document.text_content
  in
  Option.bind title String_util.trim_nonempty

let meta_content nodes attribute value =
  Markup_document.elements_named "meta" nodes
  |> List.find_map (fun node ->
         match
           Markup_document.attribute attribute node,
           Markup_document.attribute "content" node
         with
         | Some actual, Some content
           when String.equal
                  (String.lowercase_ascii (String.trim actual))
                  value ->
           String_util.trim_nonempty content
         | _ -> None)

let extract_description html =
  let nodes = Markup_document.parse_html html in
  match meta_content nodes "property" "og:description" with
  | Some _ as description -> description
  | None -> meta_content nodes "name" "description"

(** URL validation — shared with the search tool, which already owns the
    scheme test; see {!Tool_misc_web_search.valid_search_result_url}. *)
let valid_url = Tool_misc_web_search.valid_search_result_url

let ends_with ~suffix value =
  let value_length = String.length value in
  let suffix_length = String.length suffix in
  suffix_length <= value_length
  && String.equal
       (String.sub value (value_length - suffix_length) suffix_length)
       suffix

let horizontal_space_re = Re.Pcre.re "[ \t\r]+" |> Re.compile
let blank_lines_re = Re.Pcre.re "\n{3,}" |> Re.compile

let longest_nonempty nodes =
  List.fold_left
    (fun best node ->
      let candidate = Markup_document.text_content node |> String.trim in
      if String.equal candidate "" then best
      else
        match best with
        | None -> Some (node, String.length candidate)
        | Some (_, current_length) ->
          if String.length candidate > current_length
          then Some (node, String.length candidate)
          else best)
    None
    nodes

let ignored_elements =
  [ "script"; "style"; "noscript"; "svg"; "canvas"; "template"; "iframe"
  ; "nav"; "footer"; "aside"; "form"
  ]

let rec prune_node = function
  | Markup_document.Text _ as node -> Some node
  | Markup_document.Element element ->
    if List.mem element.name ignored_elements then None
    else
      Some
        (Markup_document.Element
           { element with children = List.filter_map prune_node element.children })

let select_readable_nodes html =
  let document = Markup_document.parse_html html in
  let selected, source =
    match longest_nonempty (Markup_document.elements_named "article" document) with
    | Some (article, _) -> [ article ], Article
    | None ->
      (match longest_nonempty (Markup_document.elements_named "main" document) with
       | Some (main, _) -> [ main ], Main
       | None ->
         (match Markup_document.first_element_named "body" document with
          | Some body -> [ body ], Body
          | None -> document, Document))
  in
  List.filter_map prune_node selected, source

let normalize_markdown text =
  let lines =
    text
    |> Re.replace_string horizontal_space_re ~by:" "
    |> String.split_on_char '\n'
    |> List.map String.trim
  in
  let buf = Buffer.create (String.length text) in
  let previous_blank = ref true in
  List.iter
    (fun line ->
      if String.equal line "" then (
        if not !previous_blank then (
          Buffer.add_char buf '\n';
          previous_blank := true))
      else (
        if Buffer.length buf > 0 && not !previous_blank then Buffer.add_char buf '\n';
        Buffer.add_string buf line;
        previous_blank := false))
    lines;
  Buffer.contents buf |> Re.replace_string blank_lines_re ~by:"\n\n" |> String.trim

let rec render_markdown_node = function
  | Markup_document.Text value -> value
  | Markup_document.Element element ->
    let content =
      element.children |> List.map render_markdown_node |> String.concat ""
    in
    (match element.name with
     | "a" ->
       let label = Tool_misc_web_search.clean_search_text content in
       (match List.assoc_opt "href" element.attributes with
        | Some href when valid_url href && not (String.equal label "") ->
          Printf.sprintf "[%s](%s)" label href
        | _ -> label)
     | "h1" | "h2" | "h3" | "h4" | "h5" | "h6" ->
       let level = Char.code element.name.[1] - Char.code '0' in
       let label = Tool_misc_web_search.clean_search_text content in
       if String.equal label "" then "\n"
       else "\n" ^ String.make level '#' ^ " " ^ label ^ "\n"
     | "br" -> "\n"
     | "li" -> "\n- " ^ content ^ "\n"
     | "p" | "div" | "section" | "tr" | "table" | "ul" | "ol" ->
       "\n" ^ content ^ "\n"
     | _ -> content)

let render_markdown nodes =
  nodes |> List.map render_markdown_node |> String.concat "" |> normalize_markdown

let render_extracted_text ~extract_mode html =
  let readable, source = select_readable_nodes html in
  let text =
    match extract_mode with
    | Markdown -> render_markdown readable
    | Text ->
      readable
      |> List.map Markup_document.text_content
      |> String.concat ""
      |> Tool_misc_web_search.clean_search_text
  in
  text, source

let content_type_base raw =
  match String.split_on_char ';' raw with
  | base :: _ -> String.lowercase_ascii (String.trim base)
  | [] -> String.lowercase_ascii (String.trim raw)

let content_kind_of_content_type = function
  | None -> Ok Html
  | Some raw ->
      let base = content_type_base raw in
      if String.equal base "" then Ok Html
      else if String.equal base "text/html"
              || String.equal base "application/xhtml+xml"
              || ends_with ~suffix:"+html" base
      then Ok Html
      else if String.equal base "text/plain"
              || String.equal base "text/markdown"
              || String.equal base "text/csv"
      then Ok Plain_text
      else if String.equal base "application/json"
              || ends_with ~suffix:"+json" base
      then Ok Json_text
      else if String.equal base "text/xml"
              || String.equal base "application/xml"
              || ends_with ~suffix:"+xml" base
      then Ok Xml_text
      else if String.starts_with ~prefix:"text/" base then Ok Plain_text
      else Error raw

let normalize_raw_text text =
  text |> Re.replace_string horizontal_space_re ~by:" " |> normalize_markdown

let render_payload ~extract_mode ~content_kind payload =
  match content_kind with
  | Html -> render_extracted_text ~extract_mode payload
  | Plain_text -> (normalize_raw_text payload, Raw_text)
  | Json_text | Xml_text -> (String.trim payload, Raw_text)

let truncate_text ~max_chars text =
  if String.length text <= max_chars then text, false
  else String.sub text 0 max_chars ^ "\n[TRUNCATED]", true

(** Response cache. Authorization and admission belong to the Keeper Gate; this
    leaf does not maintain a second, process-local request limiter. *)
type cache_entry = {
  response : Yojson.Safe.t;
  expires_at : float;
}

let initial_cache_capacity = 32
let cache_entries : (string, cache_entry) Hashtbl.t =
  Hashtbl.create initial_cache_capacity
let cache_mutex = Eio.Mutex.create ()
let cache_ttl_sec () = Env_config.Tools.web_search_cache_ttl_sec ()

let cache_lookup key now =
  let ttl = cache_ttl_sec () in
  if Stdlib.Float.compare ttl 0.0 <= 0 then None
  else
    Eio.Mutex.use_rw ~protect:true cache_mutex (fun () ->
        Hashtbl.filter_map_inplace
          (fun _ entry ->
            if Stdlib.Float.compare entry.expires_at now <= 0 then None
            else Some entry)
          cache_entries;
        match Hashtbl.find_opt cache_entries key with
        | Some entry when Stdlib.Float.compare entry.expires_at now > 0 ->
            Some entry.response
        | _ -> None)

let cache_store key response now =
  let ttl = cache_ttl_sec () in
  if Stdlib.Float.compare ttl 0.0 > 0 then
    Eio.Mutex.use_rw ~protect:true cache_mutex (fun () ->
        Hashtbl.replace cache_entries key { response; expires_at = now +. ttl })

(** Redact transport error detail before the " for " suffix *)
let redact_transport_error_detail message =
  match String.index_opt message ' ' with
  | Some idx -> String.sub message 0 idx
  | None -> message

(* RFC-0189 PR-1b.8 — typed fetch-failure variant. Each arm carries
   the data needed to render an operator-facing message AND a
   [tool_failure_class] tag. This SSOT keeps message formatting (in
   [fetch_failure_to_string]) and class assignment (in
   [fetch_failure_class]) co-located with construction — no
   substring re-classification downstream. *)
type fetch_failure =
  | Transport_error of string   (* raw transport-layer detail, already redacted *)
  | Http_status of int          (* upstream returned a non-2xx HTTP status *)
  | No_http_status              (* protocol level: status line missing *)
  | Invalid_redirect of string  (* redirect target is not a typed HTTP(S) URL *)
  | Redirect_limit_exceeded
  | Unsupported_content_type of string

let fetch_failure_to_string = function
  | Transport_error detail -> Printf.sprintf "fetch failed: %s" detail
  | Http_status status -> Printf.sprintf "HTTP %d" status
  | No_http_status -> "no HTTP status received"
  | Invalid_redirect reason -> "invalid redirect: " ^ reason
  | Redirect_limit_exceeded ->
      Printf.sprintf "redirect limit exceeded (max %d)" max_redirects
  | Unsupported_content_type content_type ->
      Printf.sprintf "unsupported content type: %s" content_type

let fetch_failure_class : fetch_failure -> Tool_result.tool_failure_class =
  function
  | Transport_error _ -> Tool_result.Transient_error
  | Http_status _ -> Tool_result.Runtime_failure
  | No_http_status -> Tool_result.Runtime_failure
  | Invalid_redirect _ -> Tool_result.Workflow_rejection
  | Redirect_limit_exceeded -> Tool_result.Runtime_failure
  | Unsupported_content_type _ -> Tool_result.Runtime_failure

type fetch_response =
  { http_status : int option
  ; final_url : string
  ; redirect_count : int
  ; content_type : string option
  ; downloaded_bytes : int option
  ; body : string
  }

type http_fetch =
  timeout_sec:int ->
  headers:(string * string) list ->
  max_response_bytes:int ->
  string ->
  (fetch_response, fetch_failure) Result.t

let resolve_redirect_url ~base_url target =
  Uri.resolve "" (Uri.of_string base_url) (Uri.of_string target) |> Uri.to_string

let redirect_status = function
  | Some status -> status >= 300 && status < 400
  | None -> false

let fetch_response_of_http_response ~request_url ~redirect_count
    (response : Tool_local_runtime_http.http_get_response) =
  { http_status = response.http_status
  ; final_url =
      Option.value response.effective_url ~default:request_url
      |> String.trim
  ; redirect_count
  ; content_type = response.content_type
  ; downloaded_bytes = response.downloaded_bytes
  ; body = response.body
  }

let validate_redirect_target target =
  if not (valid_url target) then
    Error "redirect target must be a valid http or https URL"
  else Ok ()

let default_http_fetch ~timeout_sec ~headers ~max_response_bytes url =
  let rec loop ~redirect_count request_url =
    match
      Tool_local_runtime_http.http_get_text_response_with_headers
        ~timeout_sec
        ~headers
        ~follow_redirects:false
        ~compressed:true
        ~max_response_bytes
        request_url
    with
    | Error detail ->
        Error (Transport_error (redact_transport_error_detail detail))
    | Ok response when redirect_status response.http_status -> (
        match response.redirect_url with
        | None | Some "" ->
            Ok (fetch_response_of_http_response ~request_url ~redirect_count response)
        | Some redirect_url ->
            if redirect_count >= max_redirects then Error Redirect_limit_exceeded
            else
              let next_url =
                resolve_redirect_url ~base_url:request_url redirect_url
              in
              match validate_redirect_target next_url with
              | Error reason -> Error (Invalid_redirect reason)
              | Ok () -> loop ~redirect_count:(redirect_count + 1) next_url)
    | Ok response ->
        Ok (fetch_response_of_http_response ~request_url ~redirect_count response)
  in
  loop ~redirect_count:0 url

let http_fetch_mutex = Mutex.create ()
let http_fetch_ref = ref default_http_fetch

let current_http_fetch () =
  Mutex.protect http_fetch_mutex (fun () -> !http_fetch_ref)

let with_http_fetch_for_test http_fetch f =
  let previous =
    Mutex.protect http_fetch_mutex (fun () ->
        let previous = !http_fetch_ref in
        http_fetch_ref := http_fetch;
        previous)
  in
  Stdlib.Fun.protect
    ~finally:(fun () ->
      Mutex.protect http_fetch_mutex (fun () -> http_fetch_ref := previous))
    f

let with_http_get_for_test http_get f =
  with_http_fetch_for_test
    (fun ~timeout_sec ~headers ~max_response_bytes url ->
      match http_get ~timeout_sec ~headers ~max_response_bytes url with
      | Ok (http_status, body) ->
          Ok
            { http_status
            ; final_url = url
            ; redirect_count = 0
            ; content_type = None
            ; downloaded_bytes = Some (String.length body)
            ; body
            }
      | Error detail ->
          Error (Transport_error (redact_transport_error_detail detail)))
    f

(** Main fetch implementation *)
let fetch_impl ~url ~timeout_sec ~extract_mode ~max_chars =
  let headers =
    [
      ( "User-Agent",
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 \
         (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36 MASC-FetchWeb/1.0" );
      ("Accept", "text/html,application/xhtml+xml,text/plain;q=0.9,*/*;q=0.5");
      ("Accept-Language", "en-US,en;q=0.8,ko;q=0.7");
    ]
  in
  match (current_http_fetch ()) ~timeout_sec ~headers ~max_response_bytes url with
  | Error failure -> Error failure
  | Ok response -> (
      match response.http_status with
      | Some status when status >= 200 && status < 300 -> (
          match content_kind_of_content_type response.content_type with
          | Error content_type -> Error (Unsupported_content_type content_type)
          | Ok content_kind ->
              let title =
                match content_kind with
                | Html -> extract_title response.body
                | Plain_text | Json_text | Xml_text -> None
              in
              let description =
                match content_kind with
                | Html -> extract_description response.body
                | Plain_text | Json_text | Xml_text -> None
              in
              let rendered, extraction_source =
                render_payload ~extract_mode ~content_kind response.body
              in
              let text, truncated = truncate_text ~max_chars rendered in
              Ok
                ( response
                , status
                , content_kind
                , extraction_source
                , title
                , description
                , text
                , truncated ))
      | Some status -> Error (Http_status status)
      | None -> Error No_http_status)

(* RFC-0189 PR-1b.8 — typed result.
   Failure-class assignments live with construction:
   - [Workflow_rejection]: caller-input violation (invalid URL).
   - [Transient_error]:    rate-limit hit + transport-level failure
                           ([fetch_failure_class] for transport).
                           Both retry-friendly by nature; clients can
                           now back off automatically based on the
                           tag instead of pattern-matching the message
                           string.
   - [Runtime_failure]:    upstream HTTP non-2xx or missing status —
                           server-side or malformed, retry is not
                           always safe.

   Note: no substring classifier downstream. Each [fetch_failure]
   variant carries its own [fetch_failure_class], assigned at the
   call site that constructs it. Avoids the workaround signature
   §2 anti-pattern (string-based classification). *)

let handle ~tool_name ~start_time args : Tool_result.result =
  let url = get_string args "url" "" in
  let timeout = max 1 (min 60 (get_int args "timeout" default_timeout_sec)) in
  let max_chars = max 1 (min max_chars_cap (get_int args "maxChars" default_max_chars)) in
  let extract_mode_raw =
    get_string args "extractMode" (extract_mode_to_string default_extract_mode)
  in
  let make_workflow_err message =
    Tool_result.make_err
      ~tool_name
      ~class_:Tool_result.Workflow_rejection
      ~start_time
      message
  in
  if not (valid_url url) then
    make_workflow_err "url must be a valid http or https URL"
  else
    match extract_mode_of_string extract_mode_raw with
    | None -> make_workflow_err "extractMode must be one of: markdown, text"
    | Some extract_mode ->
      let extract_mode_label = extract_mode_to_string extract_mode in
      let ok_from_data data =
        Tool_result.make_ok ~tool_name ~start_time ~data ()
      in
      let now = Unix.gettimeofday () in
      let key =
        String.concat
          "|"
          [ url; Int.to_string timeout; extract_mode_label; Int.to_string max_chars ]
      in
      match cache_lookup key now with
      | Some cached -> ok_from_data cached
      | None ->
        (match fetch_impl ~url ~timeout_sec:timeout ~extract_mode ~max_chars with
                    | Ok
                        ( response
                        , http_status
                        , content_kind
                        , extraction_source
                        , title
                        , description
                        , text
                        , truncated ) ->
                        let fields =
                          [
                            ("url", `String url);
                            ("final_url", `String response.final_url);
                            ("http_status", `Int http_status);
                            ("redirect_count", `Int response.redirect_count);
                            ("extract_mode", `String extract_mode_label);
                            ("content_kind", `String (content_kind_to_string content_kind));
                            ( "extraction_source",
                              `String (extraction_source_to_string extraction_source) );
                            ("text", `String text);
                            ("content_chars", `Int (String.length text));
                            ("truncated", `Bool truncated);
                          ]
                          @
                          (match response.content_type with
                          | Some value -> [ ("content_type", `String value) ]
                          | None -> [])
                          @
                          (match response.downloaded_bytes with
                          | Some value -> [ ("downloaded_bytes", `Int value) ]
                          | None -> [])
                          @
                          (match title with
                          | Some t -> [ ("title", `String t) ]
                          | None -> [])
                          @
                          (match description with
                          | Some d -> [ ("description", `String d) ]
                          | None -> [])
                        in
                        let data = Tool_args.ok_assoc fields in
                        cache_store key data now;
                        ok_from_data data
         | Error failure ->
           Tool_result.make_err
             ~tool_name
             ~class_:(fetch_failure_class failure)
             ~start_time
             (fetch_failure_to_string failure))
