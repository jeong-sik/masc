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

type normalized_hit = {
  title : string;
  url : string;
  snippet : string;
  source : string;
  rank : int;
  published_at : string option;
}

type provider =
  | Searxng
  | Brave
  | Tavily
  | Exa
  | Bing_api
  | Ddg
  | Bing_rss

type provider_response = {
  engine : string;
  search_url : string;
  hits : normalized_hit list;
}

type simulated_provider_outcome =
  [ `Error of string
  | `Empty
  | `Hits of (string * string * string) list
  ]

let whitespace_re = Re.Pcre.re "[ \t\r\n]+" |> Re.compile
let html_tag_re = Re.Pcre.re "<[^>]+>" |> Re.compile
let cdata_start_re = Re.str "<![CDATA[" |> Re.compile
let cdata_end_re = Re.str "]]>" |> Re.compile
let rss_re = Re.Pcre.re "<rss\\b" |> Re.compile
let channel_re = Re.Pcre.re "<channel\\b" |> Re.compile
let item_re = Re.Pcre.re "<item\\b[^>]*>([\\s\\S]*?)</item>" |> Re.compile
let title_re = Re.Pcre.re "<title>([\\s\\S]*?)</title>" |> Re.compile
let link_re = Re.Pcre.re "<link>([\\s\\S]*?)</link>" |> Re.compile
let description_re = Re.Pcre.re "<description>([\\s\\S]*?)</description>" |> Re.compile

let ddg_result_re = Re.Pcre.re
  {|<a rel="nofollow" class="result__a" href="[^"]*uddg=([^&"]+)[^"]*">([^<]*(?:<b>[^<]*</b>[^<]*)*)</a>|}
  |> Re.compile

let ddg_snippet_re = Re.Pcre.re
  {|<a class="result__snippet"[^>]*>([^<]*(?:<b>[^<]*</b>[^<]*)*)</a>|}
  |> Re.compile

let html_entity_replacements =
  [
    ("&amp;", "&");
    ("&lt;", "<");
    ("&gt;", ">");
    ("&quot;", "\"");
    ("&#39;", "'");
    ("&#039;", "'");
    ("&nbsp;", " ");
  ]
  |> List.map (fun (entity, replacement) ->
         (Re.str entity |> Re.compile, replacement))

let normalize_spaces text =
  text |> Re.replace_string whitespace_re ~by:" " |> String.trim

let strip_html_tags text =
  Re.replace_string html_tag_re ~by:"" text

let strip_cdata text =
  text
  |> Re.replace_string cdata_start_re ~by:""
  |> Re.replace_string cdata_end_re ~by:""

let decode_html_entities text =
  let basic =
    html_entity_replacements
    |> List.fold_left
         (fun acc (entity_re, replacement) ->
           Re.replace_string entity_re ~by:replacement acc)
         text
  in
  let len = String.length basic in
  let buf = Buffer.create len in
  let decode_numeric entity =
    let body = String.sub entity 2 (String.length entity - 3) in
    let maybe_n =
      if String.length body > 1
         && (Char.equal body.[0] 'x' || Char.equal body.[0] 'X')
      then Stdlib.int_of_string_opt ("0" ^ body)
      else Stdlib.int_of_string_opt body
    in
    match maybe_n with
    | Some n -> Stdlib.Uchar.of_int n |> Stdlib.Buffer.add_utf_8_uchar buf; Some ""
    | None -> None
  in
  let rec loop index =
    if index >= len then
      Buffer.contents buf
    else if not (Char.equal basic.[index] '&') then (
      Buffer.add_char buf basic.[index];
      loop (index + 1))
    else
      match String.index_from_opt basic index ';' with
      | None ->
          Buffer.add_char buf basic.[index];
          loop (index + 1)
      | Some semi ->
          let entity = String.sub basic index (semi - index + 1) in
          if String.length entity >= 4
             && String.starts_with ~prefix:"&#" entity
          then (
            match decode_numeric entity with
            | Some _ -> loop (semi + 1)
            | None ->
                Buffer.add_string buf entity;
                loop (semi + 1))
          else (
            Buffer.add_string buf entity;
            loop (semi + 1))
  in
  loop 0

let clean_search_text text =
  text |> strip_cdata |> strip_html_tags |> decode_html_entities |> normalize_spaces


let valid_search_result_url url =
  let trimmed = String.trim url in
  if String.equal trimmed "" then
    false
  else
    let uri = Uri.of_string trimmed in
    match Uri.scheme uri |> Option.map String.lowercase_ascii with
    | Some "http" | Some "https" -> true
    | _ -> false

let search_field field_re block =
  match Re.exec_opt field_re block with
  | None -> None
  | Some groups -> Some (Re.Group.get groups 1 |> clean_search_text)

let parse_bing_rss_items payload =
  Re.all item_re payload
  |> List.filter_map (fun groups ->
         let block = Re.Group.get groups 1 in
         match
           search_field title_re block,
           search_field link_re block,
           search_field description_re block
         with
         | Some title, Some url, Some snippet
           when not (String.equal title "") && valid_search_result_url url ->
             Some (title, url, snippet)
         | Some title, Some url, None
           when not (String.equal title "") && valid_search_result_url url ->
             Some (title, url, "")
         | _ -> None)

let parse_ddg_html payload =
  let results = Re.all ddg_result_re payload in
  let snippets = Re.all ddg_snippet_re payload in
  List.mapi (fun i groups ->
    let url_encoded = Re.Group.get groups 1 in
    let title_raw = Re.Group.get groups 2 in
    let url = Uri.pct_decode url_encoded in
    let title = clean_search_text title_raw in
    let snippet =
      match List.nth_opt snippets i with
      | Some sg -> clean_search_text (Re.Group.get sg 1)
      | None -> ""
    in
    (title, url, snippet)
  ) results
  |> List.filter (fun (title, url, _snippet) -> not (String.equal title "") && valid_search_result_url url)

let parse_json_search_results ~results_path ~title_field ~snippet_field payload =
  let str_of item key =
    Safe_ops.protect ~default:None (fun () ->
      Option.bind (Json_util.get_string item key) String_util.trim_nonempty)
  in
  Safe_ops.protect ~default:[] (fun () ->
    let root = Yojson.Safe.from_string payload in
    let items =
      Safe_ops.protect ~default:[] (fun () ->
        match results_path root with
        | `List xs -> xs
        | _ -> [])
    in
    items
    |> List.filter_map (fun item ->
           match str_of item title_field, str_of item "url" with
           | Some title, Some url when valid_search_result_url url ->
               let snippet = str_of item snippet_field |> Option.value ~default:"" in
               Some (title, url, snippet)
           | _ -> None))

let parse_searxng_json payload =
  parse_json_search_results
    ~results_path:(fun j -> Json_util.assoc_member_opt "results" j |> Option.value ~default:`Null)
    ~title_field:"title" ~snippet_field:"content" payload

let parse_brave_json payload =
  parse_json_search_results
    ~results_path:(fun j ->
      let web = Json_util.assoc_member_opt "web" j |> Option.value ~default:`Null in
      Json_util.assoc_member_opt "results" web |> Option.value ~default:`Null)
    ~title_field:"title" ~snippet_field:"description" payload

let parse_tavily_json payload =
  parse_json_search_results
    ~results_path:(fun j -> Json_util.assoc_member_opt "results" j |> Option.value ~default:`Null)
    ~title_field:"title" ~snippet_field:"content" payload

let parse_exa_json payload =
  parse_json_search_results
    ~results_path:(fun j -> Json_util.assoc_member_opt "results" j |> Option.value ~default:`Null)
    ~title_field:"title" ~snippet_field:"text" payload

let parse_bing_search_json payload =
  parse_json_search_results
    ~results_path:(fun j ->
      let web = Json_util.assoc_member_opt "webPages" j |> Option.value ~default:`Null in
      Json_util.assoc_member_opt "value" web |> Option.value ~default:`Null)
    ~title_field:"name" ~snippet_field:"snippet" payload

let looks_like_rss_payload payload =
  let normalized = String.lowercase_ascii payload in
  String.contains normalized '<'
  && (Re.execp rss_re normalized || Re.execp channel_re normalized)

let provider_to_string = function
  | Searxng -> "searxng"
  | Brave -> "brave"
  | Tavily -> "tavily"
  | Exa -> "exa"
  | Bing_api -> "bing_api"
  | Ddg -> "duckduckgo"
  | Bing_rss -> "bing_rss"

let provider_of_string raw =
  match String.lowercase_ascii (String.trim raw) with
  | "searxng" | "searx" -> Some Searxng
  | "brave" -> Some Brave
  | "tavily" -> Some Tavily
  | "exa" -> Some Exa
  | "bing" | "bing_api" -> Some Bing_api
  | "ddg" | "duckduckgo" -> Some Ddg
  | "bing_rss" | "bing-rss" -> Some Bing_rss
  | "auto" | "" -> None
  | _ -> None

let parse_provider_csv raw =
  raw
  |> String.split_on_char ','
  |> List.filter_map provider_of_string
  |> List.map provider_to_string
  |> Json_util.dedupe_keep_order
  |> List.filter_map provider_of_string

let env_present name =
  match Env_config_core.raw_value_opt name |> Option.map String.trim with
  | Some value when not (String.equal value "") -> true
  | _ -> false

let provider_has_credentials = function
  | Searxng -> env_present "MASC_SEARXNG_URL"
  | Brave -> env_present "BRAVE_SEARCH_API_KEY"
  | Tavily -> env_present "TAVILY_API_KEY"
  | Exa -> env_present "EXA_API_KEY"
  | Bing_api ->
      env_present "BING_SEARCH_API_KEY" || env_present "AZURE_BING_SEARCH_API_KEY"
  | Ddg | Bing_rss -> true

let default_provider_order () =
  [ Searxng; Brave; Tavily; Exa; Bing_api ]
  |> List.filter provider_has_credentials
  |> fun official -> official @ [ Ddg; Bing_rss ]

let provider_order () =
  match Env_config.Tools.web_search_provider_order_opt () with
  | Some raw ->
      let configured = parse_provider_csv raw in
      if Stdlib.List.length configured = 0 then default_provider_order ()
      else configured
  | None ->
      let primary =
        match Env_config.Tools.web_search_provider_opt () with
        | Some raw -> parse_provider_csv raw
        | None -> []
      in
      let fallbacks =
        match Env_config.Tools.web_search_fallbacks_opt () with
        | Some raw -> parse_provider_csv raw
        | None -> []
      in
      primary @ fallbacks @ default_provider_order ()
      |> List.map provider_to_string
      |> Json_util.dedupe_keep_order
      |> List.filter_map provider_of_string

let provider_plan () =
  provider_order () |> List.map provider_to_string

let validate_query query =
  let normalized = normalize_spaces query in
  if String.equal normalized "" then
    Error "query is required"
  else
    Ok normalized

let take_results limit hits =
  let rec loop remaining acc = function
    | _ when remaining <= 0 -> List.rev acc
    | [] -> List.rev acc
    | hit :: rest -> loop (remaining - 1) (hit :: acc) rest
  in
  loop limit [] hits

let normalize_hits ~source tuples =
  tuples
  |> List.filter (fun (title, url, _snippet) -> not (String.equal title "") && valid_search_result_url url)
  |> List.mapi (fun idx (title, url, snippet) ->
         {
           title;
           url;
           snippet = clean_search_text snippet;
           source;
           rank = idx + 1;
           published_at = None;
         })

let result_data ~query ~search_url ~engine hits =
  let results =
    hits
    |> List.map (fun hit ->
           `Assoc
             [
               ("title", `String hit.title);
               ("url", `String hit.url);
               ("snippet", `String hit.snippet);
               ("source", `String hit.source);
               ("rank", `Int hit.rank);
               ("published_at", Json_util.string_opt_to_json hit.published_at);
             ])
  in
  Tool_args.ok_assoc
    [
      ( "result",
        `Assoc
          [
            ("query", `String query);
            ("engine", `String engine);
            ("search_url", `String search_url);
            ("result_count", `Int (List.length hits));
            ("results", `List results);
          ] );
    ]

let provider_error provider message =
  Printf.sprintf "%s: %s" (provider_to_string provider) message

(** Truncate transport errors before the " for " suffix that usually prefixes
    the request URL, so provider failure messages keep the useful curl detail
    without echoing search queries or other URL payloads. *)
let redact_transport_error_detail message =
  let len = String.length message in
  let rec find_marker i =
    if i + 5 > len then
      None
    else if
      Char.equal message.[i] ' '
      && Char.equal message.[i + 1] 'f'
      && Char.equal message.[i + 2] 'o'
      && Char.equal message.[i + 3] 'r'
      && Char.equal message.[i + 4] ' '
    then
      Some i
    else
      find_marker (i + 1)
  in
  match find_marker 0 with
  | Some idx -> String.sub message 0 idx
  | None -> message

let endpoint_error ~fallback detail =
  let detail = redact_transport_error_detail detail |> String.trim in
  if String.equal detail "" then fallback else Printf.sprintf "%s (%s)" fallback detail

let searxng_default_url = Masc_network_defaults.searxng_default_url

let strip_trailing_slashes = Env_config_core.strip_trailing_slashes

let searxng_base_url () =
  let url =
    match Env_config_core.raw_value_opt "MASC_SEARXNG_URL" with
    | Some raw ->
        let normalized = raw |> String.trim |> strip_trailing_slashes in
        if String.equal normalized "" then searxng_default_url else normalized
    | None -> searxng_default_url
  in
  match Uri.scheme (Uri.of_string url) |> Option.map String.lowercase_ascii with
  | Some "http" | Some "https" -> Ok url
  | _ ->
      Error (Printf.sprintf "MASC_SEARXNG_URL must use http or https scheme (got: %s)" url)

let fetch_searxng ~timeout_sec ~query =
  match searxng_base_url () with
  | Error msg -> Error msg
  | Ok base ->
      let search_url =
        base ^ "/search?q=" ^ Uri.pct_encode query ^ "&format=json"
      in
      match
        Tool_local_runtime_http.http_get_text_with_status ~timeout_sec search_url
      with
      | Error detail ->
          Error (endpoint_error ~fallback:"search endpoint unavailable" detail)
      | Ok (Some 200, payload) -> Ok (search_url, payload)
      | Ok (Some status, _) ->
          Error (Printf.sprintf "search endpoint returned HTTP %d" status)
      | Ok (None, _) -> Error "search endpoint returned no HTTP status"

let fetch_ddg_html ~timeout_sec ~query =
  let search_url =
    "https://html.duckduckgo.com/html/?q=" ^ Uri.pct_encode query
  in
  match
    Tool_local_runtime_http.http_get_text_with_status ~timeout_sec search_url
  with
  | Error detail ->
      Error (endpoint_error ~fallback:"search endpoint unavailable" detail)
  | Ok (Some 200, payload) -> Ok (search_url, payload)
  | Ok (Some status, _) ->
      Error (Printf.sprintf "search endpoint returned HTTP %d" status)
  | Ok (None, _) -> Error "search endpoint returned no HTTP status"

let fetch_bing_rss ~timeout_sec ~query =
  let search_url =
    "https://www.bing.com/search?format=rss&q=" ^ Uri.pct_encode query
  in
  match
    Tool_local_runtime_http.http_get_text_with_status ~timeout_sec search_url
  with
  | Error detail ->
      Error (endpoint_error ~fallback:"search endpoint unavailable" detail)
  | Ok (Some 200, payload) -> Ok (search_url, payload)
  | Ok (Some status, _) ->
      Error (Printf.sprintf "search endpoint returned HTTP %d" status)
  | Ok (None, _) -> Error "search endpoint returned no HTTP status"

let fetch_brave ~timeout_sec ~query ~limit =
  match Sys.getenv_opt "BRAVE_SEARCH_API_KEY" |> Stdlib.Fun.flip Option.bind String_util.trim_nonempty with
  | None -> Error "missing BRAVE_SEARCH_API_KEY"
  | Some api_key ->
      let search_url =
        Printf.sprintf
          "https://api.search.brave.com/res/v1/web/search?q=%s&count=%d"
          (Uri.pct_encode query) limit
      in
      match
        Tool_local_runtime_http.http_get_text_with_status_with_headers
          ~timeout_sec
          ~headers:
            [ ("Accept", "application/json"); ("X-Subscription-Token", api_key) ]
          search_url
      with
      | Error detail ->
          Error (endpoint_error ~fallback:"provider request failed" detail)
      | Ok (Some 200, payload) ->
          Safe_ops.protect
            ~default:(Error "provider returned invalid JSON")
            (fun () ->
              let hits =
                parse_brave_json payload
                |> take_results limit
                |> normalize_hits ~source:(provider_to_string Brave)
              in
              Ok { engine = provider_to_string Brave; search_url; hits })
      | Ok (Some status, _) -> Error (Printf.sprintf "provider returned HTTP %d" status)
      | Ok (None, _) -> Error "provider returned no HTTP status"

let fetch_tavily ~timeout_sec ~query ~limit =
  match Sys.getenv_opt "TAVILY_API_KEY" |> Stdlib.Fun.flip Option.bind String_util.trim_nonempty with
  | None -> Error "missing TAVILY_API_KEY"
  | Some api_key ->
      let search_url = "https://api.tavily.com/search" in
      let body_json =
        `Assoc
          [
            ("api_key", `String api_key);
            ("query", `String query);
            ("max_results", `Int limit);
            ("search_depth", `String "basic");
            ("include_answer", `Bool false);
            ("include_images", `Bool false);
            ("include_raw_content", `Bool false);
          ]
        |> Yojson.Safe.to_string
      in
      match
        Tool_local_runtime_http.http_post_json_text_with_status_with_headers
          ~timeout_sec
          ~headers:[ ("Accept", "application/json") ]
          ~url:search_url
          ~body_json ()
      with
      | Error detail ->
          Error (endpoint_error ~fallback:"provider request failed" detail)
      | Ok (Some 200, payload) ->
          Safe_ops.protect
            ~default:(Error "provider returned invalid JSON")
            (fun () ->
              let hits =
                parse_tavily_json payload
                |> take_results limit
                |> normalize_hits ~source:(provider_to_string Tavily)
              in
              Ok { engine = provider_to_string Tavily; search_url; hits })
      | Ok (Some status, _) -> Error (Printf.sprintf "provider returned HTTP %d" status)
      | Ok (None, _) -> Error "provider returned no HTTP status"

let fetch_exa ~timeout_sec ~query ~limit =
  match Sys.getenv_opt "EXA_API_KEY" |> Stdlib.Fun.flip Option.bind String_util.trim_nonempty with
  | None -> Error "missing EXA_API_KEY"
  | Some api_key ->
      let search_url = "https://api.exa.ai/search" in
      let body_json =
        `Assoc
          [
            ("query", `String query);
            ("numResults", `Int limit);
            ("type", `String "keyword");
          ]
        |> Yojson.Safe.to_string
      in
      match
        Tool_local_runtime_http.http_post_json_text_with_status_with_headers
          ~timeout_sec
          ~headers:
            [ ("Accept", "application/json"); ("x-api-key", api_key) ]
          ~url:search_url
          ~body_json ()
      with
      | Error detail ->
          Error (endpoint_error ~fallback:"provider request failed" detail)
      | Ok (Some 200, payload) ->
          Safe_ops.protect
            ~default:(Error "provider returned invalid JSON")
            (fun () ->
              let hits =
                parse_exa_json payload
                |> take_results limit
                |> normalize_hits ~source:(provider_to_string Exa)
              in
              Ok { engine = provider_to_string Exa; search_url; hits })
      | Ok (Some status, _) -> Error (Printf.sprintf "provider returned HTTP %d" status)
      | Ok (None, _) -> Error "provider returned no HTTP status"

let fetch_bing_api ~timeout_sec ~query ~limit =
  let api_key =
    match Sys.getenv_opt "BING_SEARCH_API_KEY" |> Stdlib.Fun.flip Option.bind String_util.trim_nonempty with
    | Some key -> Some key
    | None -> Sys.getenv_opt "AZURE_BING_SEARCH_API_KEY" |> Stdlib.Fun.flip Option.bind String_util.trim_nonempty
  in
  match api_key with
  | None -> Error "missing BING_SEARCH_API_KEY or AZURE_BING_SEARCH_API_KEY"
  | Some key ->
      let search_url =
        Printf.sprintf
          "https://api.bing.microsoft.com/v7.0/search?q=%s&count=%d&responseFilter=Webpages"
          (Uri.pct_encode query) limit
      in
      match
        Tool_local_runtime_http.http_get_text_with_status_with_headers
          ~timeout_sec
          ~headers:
            [
              ("Accept", "application/json");
              ("Ocp-Apim-Subscription-Key", key);
            ]
          search_url
      with
      | Error detail ->
          Error (endpoint_error ~fallback:"provider request failed" detail)
      | Ok (Some 200, payload) ->
          Safe_ops.protect
            ~default:(Error "provider returned invalid JSON")
            (fun () ->
              let hits =
                parse_bing_search_json payload
                |> take_results limit
                |> normalize_hits ~source:(provider_to_string Bing_api)
              in
              Ok { engine = provider_to_string Bing_api; search_url; hits })
      | Ok (Some status, _) -> Error (Printf.sprintf "provider returned HTTP %d" status)
      | Ok (None, _) -> Error "provider returned no HTTP status"

let fetch_provider ~query ~limit provider =
  let timeout_sec = Env_config.Tools.web_search_timeout_sec () in
  match provider with
  | Searxng -> (
      match fetch_searxng ~timeout_sec ~query with
      | Error msg -> Error msg
      | Ok (search_url, payload) ->
          let hits =
            parse_searxng_json payload
            |> take_results limit
            |> normalize_hits ~source:(provider_to_string Searxng)
          in
          Ok { engine = provider_to_string Searxng; search_url; hits })
  | Brave -> fetch_brave ~timeout_sec ~query ~limit
  | Tavily -> fetch_tavily ~timeout_sec ~query ~limit
  | Exa -> fetch_exa ~timeout_sec ~query ~limit
  | Bing_api -> fetch_bing_api ~timeout_sec ~query ~limit
  | Ddg -> (
      match fetch_ddg_html ~timeout_sec ~query with
      | Error msg -> Error msg
      | Ok (search_url, payload) ->
          let hits =
            parse_ddg_html payload
            |> take_results limit
            |> normalize_hits ~source:(provider_to_string Ddg)
          in
          Ok { engine = provider_to_string Ddg; search_url; hits })
  | Bing_rss -> (
      match fetch_bing_rss ~timeout_sec ~query with
      | Error msg -> Error msg
      | Ok (search_url, payload) when looks_like_rss_payload payload ->
          let hits =
            parse_bing_rss_items payload
            |> take_results limit
            |> normalize_hits ~source:(provider_to_string Bing_rss)
          in
          Ok { engine = provider_to_string Bing_rss; search_url; hits }
      | Ok _ -> Error "provider returned invalid RSS")

let cache_key ~query ~limit =
  String.concat "|"
    [ query; Int.to_string limit; String.concat "," (provider_plan ()) ]

type cache_entry = {
  response : Yojson.Safe.t;
  expires_at : float;
}

let initial_cache_capacity = 32
let cache_entries : (string, cache_entry) Hashtbl.t = Hashtbl.create initial_cache_capacity
let cache_mutex = Eio.Mutex.create ()

let cache_lookup key now =
  let ttl = Env_config.Tools.web_search_cache_ttl_sec () in
  if Stdlib.Float.compare ttl 0.0 <= 0 then
    None
  else
    Eio.Mutex.use_rw ~protect:true cache_mutex (fun () ->
        Hashtbl.filter_map_inplace
          (fun _ entry -> if Stdlib.Float.compare entry.expires_at now <= 0 then None else Some entry)
          cache_entries;
        match Hashtbl.find_opt cache_entries key with
        | Some entry when Stdlib.Float.compare entry.expires_at now > 0 -> Some entry.response
        | _ -> None)

let cache_store key response now =
  let ttl = Env_config.Tools.web_search_cache_ttl_sec () in
  if Stdlib.Float.compare ttl 0.0 > 0 then
    Eio.Mutex.use_rw ~protect:true cache_mutex (fun () ->
        Hashtbl.replace cache_entries key { response; expires_at = now +. ttl })

let search_impl ~query ~limit =
  let rec loop errors = function
    | [] ->
        Error
          (if Stdlib.List.length errors = 0 then "no web search providers configured"
           else
             "all web search providers failed: "
             ^ String.concat "; " (List.rev errors))
    | provider :: rest -> (
        match fetch_provider ~query ~limit provider with
        | Ok ({ hits = _ :: _; _ } as response) -> Ok response
        | Ok _ -> loop (provider_error provider "no results" :: errors) rest
        | Error message -> loop (provider_error provider message :: errors) rest)
  in
  loop [] (provider_order ())

let search_impl_mutex = Mutex.create ()
let search_impl_ref = ref search_impl

let current_search_impl () =
  Mutex.protect search_impl_mutex (fun () -> !search_impl_ref)

let with_search_impl_for_test impl f =
  let previous =
    Mutex.protect search_impl_mutex (fun () ->
        let previous = !search_impl_ref in
        search_impl_ref := impl;
        previous)
  in
  Stdlib.Fun.protect
    ~finally:(fun () ->
      Mutex.protect search_impl_mutex (fun () -> search_impl_ref := previous))
    f

let simulated_search_impl ~outcomes ~query ~limit =
  let normalize source tuples =
    tuples |> take_results limit |> normalize_hits ~source
  in
  let rec loop errors = function
    | [] ->
        Error
          (if Stdlib.List.length errors = 0 then "all web search providers failed"
           else String.concat "; " (List.rev errors))
    | (provider_name, outcome) :: rest -> (
        match outcome with
        | `Hits hits when Stdlib.List.length hits > 0 ->
            Ok
              {
                engine = provider_name;
                search_url = "test://" ^ provider_name;
                hits = normalize provider_name hits;
              }
        | `Hits _ | `Empty ->
            loop ((provider_name ^ ": no results") :: errors) rest
        | `Error message ->
            loop ((provider_name ^ ": " ^ message) :: errors) rest)
  in
  loop [] outcomes

let with_simulated_search_for_test ~outcomes f =
  with_search_impl_for_test (simulated_search_impl ~outcomes) f

(* RFC-0189 PR-1b.9 — typed result. Failure-class mapping at the
   handle boundary (source-typed at each construction site; no
   substring matching):

   - [Workflow_rejection]: empty query input.
   - [Runtime_failure]:    [search_impl] aggregate ("all web
     search providers failed: ..."). The 7-provider fallback
     chain exhausted; per-provider transport vs server
     distinction is collapsed in the aggregate string today.
     Lifting fetch_provider / per-fetcher errors to typed
     variants is the natural PR-2 follow-up — the aggregate
     boundary remains [Runtime_failure] for now because
     blind-retry is not guaranteed safe (some providers may
     have returned 4xx).

   [simulate_for_test] uses the same boundary: empty outcomes
   list or aggregate failure → [Runtime_failure]. *)

let data_ok ~tool_name ~start_time data : Tool_result.result =
  Tool_result.make_ok ~tool_name ~start_time ~data ()

let workflow_err ~tool_name ~start_time msg : Tool_result.result =
  Tool_result.make_err
    ~tool_name
    ~class_:Tool_result.Workflow_rejection
    ~start_time
    msg

let runtime_err ~tool_name ~start_time msg : Tool_result.result =
  Tool_result.make_err
    ~tool_name
    ~class_:Tool_result.Runtime_failure
    ~start_time
    msg

let handle ~tool_name ~start_time args : Tool_result.result =
  let query = get_string args "query" "" in
  match validate_query query with
  | Error message -> workflow_err ~tool_name ~start_time message
  | Ok query ->
      let limit = max 1 (min 10 (get_int args "limit" 5)) in
      let now = Unix.gettimeofday () in
      let key = cache_key ~query ~limit in
      match cache_lookup key now with
      | Some cached -> data_ok ~tool_name ~start_time cached
      | None ->
        (match (current_search_impl ()) ~query ~limit with
         | Ok response ->
           let data =
             result_data ~query ~search_url:response.search_url
               ~engine:response.engine response.hits
           in
           cache_store key data now;
           data_ok ~tool_name ~start_time data
         | Error message -> runtime_err ~tool_name ~start_time message)

let simulate_for_test ~query ~limit outcomes : Tool_result.result =
  match simulated_search_impl ~outcomes ~query ~limit with
  | Ok response ->
      data_ok ~tool_name:"masc_web_search" ~start_time:0.0
        (result_data ~query
           ~search_url:response.search_url
           ~engine:response.engine
           response.hits)
  | Error message ->
      runtime_err ~tool_name:"masc_web_search" ~start_time:0.0 message
