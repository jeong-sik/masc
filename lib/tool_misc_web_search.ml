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

let max_web_search_query_length = 500

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

let json_error message =
  Yojson.Safe.to_string
    (`Assoc [ ("status", `String "error"); ("message", `String message) ])

let json_ok fields =
  Yojson.Safe.to_string (`Assoc (("status", `String "ok") :: fields))

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
         && (body.[0] = 'x' || body.[0] = 'X')
      then int_of_string_opt ("0" ^ body)
      else int_of_string_opt body
    in
    match maybe_n with
    | Some n -> Uchar.of_int n |> Buffer.add_utf_8_uchar buf; Some ""
    | None -> None
  in
  let rec loop index =
    if index >= len then
      Buffer.contents buf
    else if basic.[index] <> '&' then (
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

let trim_nonempty text =
  let trimmed = String.trim text in
  if trimmed = "" then None else Some trimmed

let valid_search_result_url url =
  let trimmed = String.trim url in
  if trimmed = "" then
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
           when title <> "" && valid_search_result_url url ->
             Some (title, url, snippet)
         | Some title, Some url, None
           when title <> "" && valid_search_result_url url ->
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
  |> List.filter (fun (title, url, _snippet) -> title <> "" && valid_search_result_url url)

let parse_json_search_results ~results_path ~title_field ~snippet_field payload =
  let open Yojson.Safe.Util in
  let str_of item key =
    Safe_ops.protect ~default:None (fun () ->
      Option.bind (member key item |> to_string_option) trim_nonempty)
  in
  Safe_ops.protect ~default:[] (fun () ->
    let root = Yojson.Safe.from_string payload in
    let items =
      Safe_ops.protect ~default:[] (fun () -> results_path root |> to_list)
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
    ~results_path:Yojson.Safe.Util.(member "results")
    ~title_field:"title" ~snippet_field:"content" payload

let parse_brave_json payload =
  parse_json_search_results
    ~results_path:(fun j -> Yojson.Safe.Util.(member "web" j |> member "results"))
    ~title_field:"title" ~snippet_field:"description" payload

let parse_tavily_json payload =
  parse_json_search_results
    ~results_path:Yojson.Safe.Util.(member "results")
    ~title_field:"title" ~snippet_field:"content" payload

let parse_exa_json payload =
  parse_json_search_results
    ~results_path:Yojson.Safe.Util.(member "results")
    ~title_field:"title" ~snippet_field:"text" payload

let parse_bing_search_json payload =
  parse_json_search_results
    ~results_path:(fun j -> Yojson.Safe.Util.(member "webPages" j |> member "value"))
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
  match Sys.getenv_opt name |> Option.map String.trim with
  | Some value when value <> "" -> true
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
      if configured = [] then default_provider_order ()
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

let is_secret_token_char = function
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '-' -> true
  | _ -> false

let contains_secret_token_prefix ~prefix ~min_suffix_len query =
  let lowered = String.lowercase_ascii query in
  let prefix_len = String.length prefix in
  let query_len = String.length lowered in
  let rec count_suffix_chars idx count =
    if idx + count >= query_len then
      count
    else if is_secret_token_char lowered.[idx + count] then
      count_suffix_chars idx (count + 1)
    else
      count
  in
  let rec loop idx =
    if idx + prefix_len > query_len then
      false
    else if String.sub lowered idx prefix_len = prefix then
      let boundary_ok = idx = 0 || not (is_secret_token_char lowered.[idx - 1]) in
      let suffix_len = count_suffix_chars (idx + prefix_len) 0 in
      if boundary_ok && suffix_len >= min_suffix_len then true else loop (idx + 1)
    else
      loop (idx + 1)
  in
  loop 0

let query_contains_secret_like_content query =
  let lowered = String.lowercase_ascii query in
  let markers =
    [
      "-----begin ";
      "authorization:";
      "bearer ";
      "x-api-key:";
      "api_key=";
      "token=";
    ]
  in
  let secret_prefixes =
    [
      ("ghp_", 8);
      ("github_pat_", 8);
      ("sk-", 10);
    ]
  in
  List.exists (fun marker -> String_util.contains_substring lowered marker) markers
  || List.exists
       (fun (prefix, min_suffix_len) ->
         contains_secret_token_prefix ~prefix ~min_suffix_len query)
       secret_prefixes

let validate_query query =
  let normalized = normalize_spaces query in
  if normalized = "" then
    Error "query is required"
  else if String.length normalized > max_web_search_query_length then
    Error
      (Printf.sprintf
         "query must be at most %d characters"
         max_web_search_query_length)
  else if query_contains_secret_like_content normalized then
    Error "query looks like it may contain secrets; refine it before using web search"
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
  |> List.filter (fun (title, url, _snippet) -> title <> "" && valid_search_result_url url)
  |> List.mapi (fun idx (title, url, snippet) ->
         {
           title;
           url;
           snippet = clean_search_text snippet;
           source;
           rank = idx + 1;
           published_at = None;
         })

let result_json ~query ~search_url ~engine hits =
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
  json_ok
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
      message.[i] = ' '
      && message.[i + 1] = 'f'
      && message.[i + 2] = 'o'
      && message.[i + 3] = 'r'
      && message.[i + 4] = ' '
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
  if detail = "" then fallback else Printf.sprintf "%s (%s)" fallback detail

let searxng_default_url = Masc_network_defaults.searxng_default_url

let strip_trailing_slashes s =
  let rec find_last_non_slash i =
    if i < 0 then -1
    else if s.[i] = '/' then find_last_non_slash (i - 1)
    else i
  in
  let last = find_last_non_slash (String.length s - 1) in
  if last < 0 then "" else String.sub s 0 (last + 1)

let searxng_base_url () =
  let url =
    match Sys.getenv_opt "MASC_SEARXNG_URL" with
    | Some raw ->
        let normalized = raw |> String.trim |> strip_trailing_slashes in
        if normalized = "" then searxng_default_url else normalized
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
  match Sys.getenv_opt "BRAVE_SEARCH_API_KEY" |> Fun.flip Option.bind trim_nonempty with
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
  match Sys.getenv_opt "TAVILY_API_KEY" |> Fun.flip Option.bind trim_nonempty with
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
  match Sys.getenv_opt "EXA_API_KEY" |> Fun.flip Option.bind trim_nonempty with
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
    match Sys.getenv_opt "BING_SEARCH_API_KEY" |> Fun.flip Option.bind trim_nonempty with
    | Some key -> Some key
    | None -> Sys.getenv_opt "AZURE_BING_SEARCH_API_KEY" |> Fun.flip Option.bind trim_nonempty
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
    [ query; string_of_int limit; String.concat "," (provider_plan ()) ]

type cache_entry = {
  response : string;
  expires_at : float;
}

let initial_cache_capacity = 32
let cache_entries : (string, cache_entry) Hashtbl.t = Hashtbl.create initial_cache_capacity
let cache_mutex = Eio.Mutex.create ()
let request_times : float Queue.t = Queue.create ()
let rate_limit_mutex = Eio.Mutex.create ()

let cache_lookup key now =
  let ttl = Env_config.Tools.web_search_cache_ttl_sec () in
  if ttl <= 0.0 then
    None
  else
    Eio.Mutex.use_rw ~protect:true cache_mutex (fun () ->
        Hashtbl.filter_map_inplace
          (fun _ entry -> if entry.expires_at <= now then None else Some entry)
          cache_entries;
        match Hashtbl.find_opt cache_entries key with
        | Some entry when entry.expires_at > now -> Some entry.response
        | _ -> None)

let cache_store key response now =
  let ttl = Env_config.Tools.web_search_cache_ttl_sec () in
  if ttl > 0.0 then
    Eio.Mutex.use_rw ~protect:true cache_mutex (fun () ->
        Hashtbl.replace cache_entries key { response; expires_at = now +. ttl })

let enforce_rate_limit now =
  let window = Env_config.Tools.web_search_rate_limit_window_sec () in
  let max_calls = Env_config.Tools.web_search_rate_limit_max_calls () in
  Eio.Mutex.use_rw ~protect:true rate_limit_mutex (fun () ->
      while Queue.length request_times > 0
            && now -. Queue.peek request_times > window
      do
        let (_ : float) = Queue.pop request_times in ()
      done;
      if Queue.length request_times >= max_calls then
        Error "web search rate limit exceeded; retry shortly"
      else (
        Queue.push now request_times;
        Ok ()))

let search_impl ~query ~limit =
  let rec loop errors = function
    | [] ->
        Error
          (if errors = [] then "no web search providers configured"
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

let handle args =
  let query = get_string args "query" "" in
  match validate_query query with
  | Error message -> (false, json_error message)
  | Ok query ->
      let limit = max 1 (min 10 (get_int args "limit" 5)) in
      let now = Unix.gettimeofday () in
      let key = cache_key ~query ~limit in
      match cache_lookup key now with
      | Some cached -> (true, cached)
      | None -> (
          match enforce_rate_limit now with
          | Error message -> (false, json_error message)
          | Ok () -> (
              match search_impl ~query ~limit with
              | Ok response ->
                  let json =
                    result_json ~query ~search_url:response.search_url
                      ~engine:response.engine response.hits
                  in
                  cache_store key json now;
                  (true, json)
              | Error message -> (false, json_error message)))

let simulate_for_test ~query ~limit outcomes =
  let normalize source tuples =
    tuples |> take_results limit |> normalize_hits ~source
  in
  let rec loop errors = function
    | [] ->
        ( false,
          json_error
            (if errors = [] then "all web search providers failed"
             else String.concat "; " (List.rev errors)) )
    | (provider_name, outcome) :: rest -> (
        match outcome with
        | `Hits hits when hits <> [] ->
            ( true,
              result_json ~query
                ~search_url:("test://" ^ provider_name)
                ~engine:provider_name
                (normalize provider_name hits) )
        | `Hits _ | `Empty ->
            loop ((provider_name ^ ": no results") :: errors) rest
        | `Error message ->
            loop ((provider_name ^ ": " ^ message) :: errors) rest)
  in
  loop [] outcomes
