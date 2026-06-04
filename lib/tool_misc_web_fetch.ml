module Format = Stdlib.Format
module Map = Stdlib.Map
module Set = Stdlib.Set
module Queue = Stdlib.Queue
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

let extract_mode_to_string = function
  | Markdown -> "markdown"
  | Text -> "text"

let extract_mode_of_string raw =
  match String.lowercase_ascii (String.trim raw) with
  | "" | "markdown" | "md" -> Some Markdown
  | "text" | "plain" | "plain_text" -> Some Text
  | _ -> None

let default_extract_mode = Markdown

(** Extract <title> from HTML *)
let title_tag_re =
  Re.Pcre.re ~flags:[ `CASELESS; `DOTALL ] "<title[^>]*>(.*?)</title>"
  |> Re.compile

let extract_title html =
  match Re.exec_opt title_tag_re html with
  | Some groups ->
      let raw = Re.Group.get groups 1 in
      let cleaned = Tool_misc_web_search.clean_search_text raw in
      if String.equal cleaned "" then None else Some cleaned
  | None -> None

(** Extract <meta name="description"> or og:description from HTML *)
let meta_description_re =
  Re.Pcre.re
    ~flags:[ `CASELESS; `DOTALL ]
    "<meta[^>]+name\\s*=\\s*['\"]description['\"][^>]+content\\s*=\\s*['\"]([^'\"]+)['\"][^>]*>"
  |> Re.compile

let meta_description_reversed_re =
  Re.Pcre.re
    ~flags:[ `CASELESS; `DOTALL ]
    "<meta[^>]+content\\s*=\\s*['\"]([^'\"]+)['\"][^>]+name\\s*=\\s*['\"]description['\"][^>]*>"
  |> Re.compile

let og_description_re =
  Re.Pcre.re
    ~flags:[ `CASELESS; `DOTALL ]
    "<meta[^>]+property\\s*=\\s*['\"]og:description['\"][^>]+content\\s*=\\s*['\"]([^'\"]+)['\"][^>]*>"
  |> Re.compile

let og_description_reversed_re =
  Re.Pcre.re
    ~flags:[ `CASELESS; `DOTALL ]
    "<meta[^>]+content\\s*=\\s*['\"]([^'\"]+)['\"][^>]+property\\s*=\\s*['\"]og:description['\"][^>]*>"
  |> Re.compile

let first_match html pattern =
  match Re.exec_opt pattern html with
  | Some groups ->
      let cleaned = Tool_misc_web_search.clean_search_text (Re.Group.get groups 1) in
      if String.equal cleaned "" then None else Some cleaned
  | None -> None

let extract_description html =
  match first_match html og_description_re with
  | Some _ as value -> value
  | None -> (
      match first_match html og_description_reversed_re with
      | Some _ as value -> value
      | None -> (
          match first_match html meta_description_re with
          | Some _ as value -> value
          | None -> first_match html meta_description_reversed_re))

(** URL validation *)
let valid_url url =
  let trimmed = String.trim url in
  if String.equal trimmed "" then false
  else
    let uri = Uri.of_string trimmed in
    match Uri.scheme uri |> Option.map String.lowercase_ascii with
    | Some "http" | Some "https" -> true
    | _ -> false

let ends_with ~suffix s =
  let len_s = String.length s in
  let len_suffix = String.length suffix in
  len_suffix <= len_s
  && String.equal (String.sub s (len_s - len_suffix) len_suffix) suffix

let ipv4_private_reason host =
  match String.split_on_char '.' host |> List.map Stdlib.int_of_string_opt with
  | [ Some a; Some b; Some _; Some _ ]
    when a = 0
         || a = 10
         || a = 127
         || a >= 224
         || (a = 169 && b = 254)
         || (a = 172 && b >= 16 && b <= 31)
         || (a = 192 && b = 168)
         || (a = 100 && b >= 64 && b <= 127)
         || (a = 198 && (b = 18 || b = 19)) ->
      Some "private/internal/special-use IPv4 address"
  | [ Some 192; Some 0; Some 2; Some _ ]
  | [ Some 198; Some 51; Some 100; Some _ ]
  | [ Some 203; Some 0; Some 113; Some _ ] ->
      Some "documentation-only IPv4 address"
  | [ Some _; Some _; Some _; Some _ ] -> None
  | _ -> None

let ipv6_private_reason host =
  let lower = String.lowercase_ascii host in
  if String.equal lower "::1"
     || String.equal lower "0:0:0:0:0:0:0:1"
     || String.equal lower "::"
  then Some "private/internal/special-use IPv6 address"
  else if String.starts_with ~prefix:"fc" lower
          || String.starts_with ~prefix:"fd" lower
          || String.starts_with ~prefix:"fe8" lower
          || String.starts_with ~prefix:"fe9" lower
          || String.starts_with ~prefix:"fea" lower
          || String.starts_with ~prefix:"feb" lower
  then Some "private/internal/special-use IPv6 address"
  else None

let blocked_host_reason url =
  let uri = Uri.of_string (String.trim url) in
  match Uri.host uri with
  | None -> Some "url must include a host"
  | Some raw_host ->
      let host = String.lowercase_ascii (String.trim raw_host) in
      if String.equal host "" then Some "url must include a host"
      else if String.equal host "localhost" || ends_with ~suffix:".localhost" host
      then Some "localhost is not allowed"
      else if String.equal host "metadata.google.internal"
              || String.equal host "169.254.169.254"
      then Some "cloud metadata endpoints are not allowed"
      else if not (String.contains host '.') && not (String.contains host ':')
      then Some "single-label internal hostnames are not allowed"
      else
        match ipv4_private_reason host with
        | Some _ as reason -> reason
        | None -> if String.contains host ':' then ipv6_private_reason host else None

let html_block_re tag =
  Re.Pcre.re
    ~flags:[ `CASELESS; `DOTALL ]
    (Printf.sprintf "<%s\\b[^>]*>[\\s\\S]*?</%s>" tag tag)
  |> Re.compile

let remove_html_noise_res =
  List.map html_block_re
    [ "script"; "style"; "noscript"; "svg"; "canvas"; "template"; "iframe" ]

let remove_boilerplate_res =
  List.map html_block_re [ "nav"; "footer"; "aside"; "form" ]

let html_comment_re =
  Re.Pcre.re ~flags:[ `DOTALL ] "<!--[\\s\\S]*?-->" |> Re.compile

let article_re =
  Re.Pcre.re ~flags:[ `CASELESS; `DOTALL ] "<article\\b[^>]*>([\\s\\S]*?)</article>"
  |> Re.compile

let main_re =
  Re.Pcre.re ~flags:[ `CASELESS; `DOTALL ] "<main\\b[^>]*>([\\s\\S]*?)</main>"
  |> Re.compile

let body_re =
  Re.Pcre.re ~flags:[ `CASELESS; `DOTALL ] "<body\\b[^>]*>([\\s\\S]*?)</body>"
  |> Re.compile

let heading_re =
  Re.Pcre.re ~flags:[ `CASELESS; `DOTALL ] "<h([1-6])\\b[^>]*>([\\s\\S]*?)</h[1-6]>"
  |> Re.compile

let link_re =
  Re.Pcre.re
    ~flags:[ `CASELESS; `DOTALL ]
    "<a\\b[^>]*href\\s*=\\s*['\"]([^'\"]+)['\"][^>]*>([\\s\\S]*?)</a>"
  |> Re.compile

let paragraph_open_re = Re.Pcre.re ~flags:[ `CASELESS ] "<p\\b[^>]*>" |> Re.compile
let paragraph_close_re = Re.Pcre.re ~flags:[ `CASELESS ] "</p>" |> Re.compile
let br_re = Re.Pcre.re ~flags:[ `CASELESS ] "<br\\s*/?>" |> Re.compile
let li_open_re = Re.Pcre.re ~flags:[ `CASELESS ] "<li\\b[^>]*>" |> Re.compile
let li_close_re = Re.Pcre.re ~flags:[ `CASELESS ] "</li>" |> Re.compile
let block_open_re =
  Re.Pcre.re ~flags:[ `CASELESS ] "<(div|section|tr|table|ul|ol)\\b[^>]*>"
  |> Re.compile
let block_close_re =
  Re.Pcre.re ~flags:[ `CASELESS ] "</(div|section|tr|table|ul|ol)>"
  |> Re.compile
let residual_tag_re = Re.Pcre.re "<[^>]+>" |> Re.compile
let horizontal_space_re = Re.Pcre.re "[ \t\r]+" |> Re.compile
let blank_lines_re = Re.Pcre.re "\n{3,}" |> Re.compile

let html_entity_replacements =
  [
    ("&amp;", "&");
    ("&lt;", "<");
    ("&gt;", ">");
    ("&quot;", "\"");
    ("&#39;", "'");
    ("&#039;", "'");
    ("&apos;", "'");
    ("&nbsp;", " ");
  ]
  |> List.map (fun (entity, replacement) ->
         (Re.str entity |> Re.compile, replacement))

let decode_html_entities text =
  List.fold_left
    (fun acc (entity_re, replacement) ->
      Re.replace_string entity_re ~by:replacement acc)
    text
    html_entity_replacements

let strip_noise html =
  remove_html_noise_res
  |> List.fold_left
       (fun acc re -> Re.replace_string re ~by:"" acc)
       (Re.replace_string html_comment_re ~by:"" html)

let longest_nonempty blocks =
  List.fold_left
    (fun best block ->
      let candidate = String.trim block in
      if String.equal candidate "" then best
      else
        match best with
        | None -> Some candidate
        | Some current ->
            if String.length candidate > String.length current then Some candidate
            else best)
    None
    blocks

let first_group pattern html =
  Re.all pattern html |> List.map (fun groups -> Re.Group.get groups 1)

let select_readable_html html =
  let html = strip_noise html in
  let selected =
    match longest_nonempty (first_group article_re html) with
    | Some article -> article
    | None -> (
        match longest_nonempty (first_group main_re html) with
        | Some main -> main
        | None -> (
            match first_group body_re html with
            | body :: _ -> body
            | [] -> html))
  in
  List.fold_left
    (fun acc re -> Re.replace_string re ~by:"" acc)
    selected
    remove_boilerplate_res

let clean_inline html =
  Tool_misc_web_search.clean_search_text html

let render_links html =
  Re.replace link_re html ~f:(fun groups ->
      let href = Re.Group.get groups 1 |> String.trim in
      let label = Re.Group.get groups 2 |> clean_inline in
      if String.equal label "" then ""
      else if valid_url href then Printf.sprintf "[%s](%s)" label href
      else label)

let render_headings html =
  Re.replace heading_re html ~f:(fun groups ->
      let level =
        Re.Group.get groups 1 |> Stdlib.int_of_string_opt |> Option.value ~default:2
      in
      let marker = String.make (max 1 (min 6 level)) '#' in
      let label = Re.Group.get groups 2 |> clean_inline in
      if String.equal label "" then "\n" else "\n" ^ marker ^ " " ^ label ^ "\n")

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

let render_markdown html =
  html
  |> render_links
  |> render_headings
  |> Re.replace_string br_re ~by:"\n"
  |> Re.replace_string paragraph_open_re ~by:"\n"
  |> Re.replace_string paragraph_close_re ~by:"\n"
  |> Re.replace_string li_open_re ~by:"\n- "
  |> Re.replace_string li_close_re ~by:"\n"
  |> Re.replace_string block_open_re ~by:"\n"
  |> Re.replace_string block_close_re ~by:"\n"
  |> Re.replace_string residual_tag_re ~by:""
  |> decode_html_entities
  |> normalize_markdown

let render_extracted_text ~extract_mode html =
  let readable = select_readable_html html in
  match extract_mode with
  | Markdown -> render_markdown readable
  | Text -> Tool_misc_web_search.clean_search_text readable

let truncate_text ~max_chars text =
  if String.length text <= max_chars then text, false
  else String.sub text 0 max_chars ^ "\n[TRUNCATED]", true

(** Cache + rate limit — same pattern as web_search but separate state *)
type cache_entry = {
  response : string;
  expires_at : float;
}

let initial_cache_capacity = 32
let cache_entries : (string, cache_entry) Hashtbl.t =
  Hashtbl.create initial_cache_capacity
let cache_mutex = Eio.Mutex.create ()
let request_times : float Queue.t = Queue.create ()
let rate_limit_mutex = Eio.Mutex.create ()

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

let enforce_rate_limit now =
  let window = Env_config.Tools.web_search_rate_limit_window_sec () in
  let max_calls = Env_config.Tools.web_search_rate_limit_max_calls () in
  Eio.Mutex.use_rw ~protect:true rate_limit_mutex (fun () ->
      while
        Queue.length request_times > 0
        && Stdlib.( > ) (Stdlib.Float.sub now (Queue.peek request_times)) window
      do
        let (_ : float) = Queue.pop request_times in
        ()
      done;
      if Queue.length request_times >= max_calls then
        Error "web fetch rate limit exceeded; retry shortly"
      else (
        Queue.push now request_times;
        Ok ()))

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

let fetch_failure_to_string = function
  | Transport_error detail -> Printf.sprintf "fetch failed: %s" detail
  | Http_status status -> Printf.sprintf "HTTP %d" status
  | No_http_status -> "no HTTP status received"

let fetch_failure_class : fetch_failure -> Tool_result.tool_failure_class =
  function
  | Transport_error _ -> Tool_result.Transient_error
  | Http_status _ -> Tool_result.Runtime_failure
  | No_http_status -> Tool_result.Runtime_failure

type http_get =
  timeout_sec:int ->
  headers:(string * string) list ->
  max_response_bytes:int ->
  string ->
  (int option * string, string) Result.t

let default_http_get ~timeout_sec ~headers ~max_response_bytes url =
  Tool_local_runtime_http.http_get_text_with_status_with_headers
    ~timeout_sec
    ~headers
    ~follow_redirects:true
    ~max_redirects
    ~compressed:true
    ~max_response_bytes
    url

let http_get_mutex = Mutex.create ()
let http_get_ref = ref default_http_get

let current_http_get () =
  Mutex.protect http_get_mutex (fun () -> !http_get_ref)

let with_http_get_for_test http_get f =
  let previous =
    Mutex.protect http_get_mutex (fun () ->
        let previous = !http_get_ref in
        http_get_ref := http_get;
        previous)
  in
  Stdlib.Fun.protect
    ~finally:(fun () ->
      Mutex.protect http_get_mutex (fun () -> http_get_ref := previous))
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
  match (current_http_get ()) ~timeout_sec ~headers ~max_response_bytes url with
  | Error detail ->
      Error (Transport_error (redact_transport_error_detail detail))
  | Ok (Some status, payload) when status >= 200 && status < 300 ->
      let title = extract_title payload in
      let description = extract_description payload in
      let rendered = render_extracted_text ~extract_mode payload in
      let text, truncated = truncate_text ~max_chars rendered in
      Ok (status, title, description, text, truncated)
  | Ok (Some status, _) -> Error (Http_status status)
  | Ok (None, _) -> Error No_http_status

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
    | Some extract_mode -> (
        match blocked_host_reason url with
        | Some reason -> make_workflow_err ("url host is blocked: " ^ reason)
        | None ->
            let extract_mode_label = extract_mode_to_string extract_mode in
            (* RFC-0189 follow-up — store the parsed JSON envelope in
               [~data] instead of wrapping as [`Assoc [ "text", `String body ]].
               The wrapped form corrupted [result.message] for callers (and
               tests) that round-tripped through [parse_json result.message],
               because the wrapper was serialised instead of the envelope. Both
               the cache and fresh paths produce [Tool_args.ok_response] strings,
               so both go through
               [structured_payload_of_message]; plain-text fallback retained
               only for defence in depth. *)
            let ok_from_envelope body =
              let data =
                match Tool_result.structured_payload_of_message body with
                | Some json -> json
                | None -> `String body
              in
              Tool_result.make_ok ~tool_name ~start_time ~data ()
            in
            let now = Unix.gettimeofday () in
            let key =
              String.concat
                "|"
                [ url; Int.to_string timeout; extract_mode_label; Int.to_string max_chars ]
            in
            match cache_lookup key now with
            | Some cached -> ok_from_envelope cached
            | None -> (
                match enforce_rate_limit now with
                | Error message ->
                    Tool_result.make_err
                      ~tool_name
                      ~class_:Tool_result.Transient_error
                      ~start_time
                      message
                | Ok () -> (
                    match fetch_impl ~url ~timeout_sec:timeout ~extract_mode ~max_chars with
                    | Ok (http_status, title, description, text, truncated) ->
                        let fields =
                          [
                            ("url", `String url);
                            ("http_status", `Int http_status);
                            ("extract_mode", `String extract_mode_label);
                            ("text", `String text);
                            ("content_chars", `Int (String.length text));
                            ("truncated", `Bool truncated);
                          ]
                          @
                          (match title with
                          | Some t -> [ ("title", `String t) ]
                          | None -> [])
                          @
                          (match description with
                          | Some d -> [ ("description", `String d) ]
                          | None -> [])
                        in
                        let json = Tool_args.ok_response fields in
                        cache_store key json now;
                        ok_from_envelope json
                    | Error failure ->
                        Tool_result.make_err
                          ~tool_name
                          ~class_:(fetch_failure_class failure)
                          ~start_time
                          (fetch_failure_to_string failure))))
