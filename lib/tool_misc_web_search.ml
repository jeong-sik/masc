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
  | Brave_llm_context
  | Tavily
  | Exa
  | Bing_api
  | Ollama

type provider_response = {
  engine : string;
  search_url : string;
  hits : normalized_hit list;
}

(* Brave LLM Context answers with pre-extracted, relevance-ranked
   chunks instead of (title, url, snippet) rows. The token budget is a
   request parameter (maximum_number_of_tokens, provider default 8192),
   so the payload arrives already sized for a model turn and nothing is
   re-truncated on our side. *)
type grounded_source = {
  source_url : string;
  source_title : string;
  snippets : string list;
}

type grounded_context = {
  context_search_url : string;
  items : grounded_source list;
}

type search_payload =
  | Hits of provider_response
  | Grounded of grounded_context

(* RFC-0189 PR-2 — per-provider errors are lifted to typed variants so the
   fallback chain can distinguish transport vs server vs config vs parse
   failures instead of collapsing them into one aggregate string. The
   aggregate boundary at [search_impl] remains [Runtime_failure] for now
   (blind-retry is not guaranteed safe), but each provider's failure is
   preserved as a typed variant. *)
type provider_error =
  | Transport of string  (* network / transport-level failure *)
  | Server of string     (* endpoint returned a non-200 status or no status *)
  | Config of string     (* missing credentials / invalid configuration *)
  | Parse of string      (* payload could not be parsed into hits *)

let provider_error_to_string = function
  | Transport msg -> "transport: " ^ msg
  | Server msg -> "server: " ^ msg
  | Config msg -> "config: " ^ msg
  | Parse msg -> "parse: " ^ msg

type simulated_provider_outcome =
  [ `Error of string
  | `Empty
  | `Hits of (string * string * string) list
  | `Grounded of (string * string * string list) list
  ]

let whitespace_re = Re.Pcre.re "[ \t\r\n]+" |> Re.compile
let normalize_spaces text =
  text |> Re.replace_string whitespace_re ~by:" " |> String.trim

let clean_search_text text =
  Markup_document.parse_html text
  |> List.map Markup_document.text_content
  |> String.concat ""
  |> normalize_spaces


let valid_search_result_url url =
  let trimmed = String.trim url in
  if String.equal trimmed "" then
    false
  else
    let uri = Uri.of_string trimmed in
    match Uri.scheme uri |> Option.map String.lowercase_ascii with
    | Some "http" | Some "https" -> true
    | _ -> false

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

let parse_ollama_search_json payload =
  parse_json_search_results
    (* Absent "results" resolves to `Null → zero hits, so the chain
       reports "no results" instead of inventing content. DET-OK *)
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

(* Total like its sibling parsers — and through the same mechanism:
   Safe_ops.protect, so every exception class malformed third-party
   input can raise (not just Json_error) degrades to []. Response
   contract:
   { "grounding": { "generic": [ { url, title, snippets: [string] } ] } } *)
let parse_brave_llm_context_json payload =
  let member_list key json =
    match Json_util.assoc_member_opt key json with
    | Some (`List entries) -> entries
    | _ -> []
  in
  Safe_ops.protect ~default:[] (fun () ->
      let json = Yojson.Safe.from_string payload in
      let generic =
        match Json_util.assoc_member_opt "grounding" json with
        | Some grounding -> member_list "generic" grounding
        | None -> []
      in
      generic
      |> List.filter_map (fun entry ->
             let string_field key =
               match Json_util.assoc_member_opt key entry with
               | Some (`String value) -> String_util.trim_nonempty value
               | _ -> None
             in
             let snippets =
               member_list "snippets" entry
               |> List.filter_map (function
                    | `String snippet -> String_util.trim_nonempty snippet
                    | _ -> None)
             in
             match string_field "url", snippets with
             | Some url, _ :: _ when valid_search_result_url url ->
                 (* DET-OK: a missing title deterministically falls back to
                    the url — documented in the .mli, visible in output. *)
                 Some (url, Option.value (string_field "title") ~default:url, snippets)
             | _ -> None))

let provider_to_string = function
  | Searxng -> "searxng"
  | Brave -> "brave"
  | Brave_llm_context -> "brave_llm_context"
  | Tavily -> "tavily"
  | Exa -> "exa"
  | Bing_api -> "bing_api"
  | Ollama -> "ollama"

let provider_of_string raw =
  match String.lowercase_ascii (String.trim raw) with
  | "searxng" | "searx" -> Some Searxng
  | "brave" -> Some Brave
  | "brave_llm_context" | "brave-llm-context" -> Some Brave_llm_context
  | "tavily" -> Some Tavily
  | "exa" -> Some Exa
  | "bing" | "bing_api" -> Some Bing_api
  | "ollama" -> Some Ollama
  | "auto" | "" -> None
  | _ -> None

let parse_provider_csv raw =
  raw
  |> String.split_on_char ','
  |> List.filter_map provider_of_string
  |> List.map provider_to_string
  |> Json_util.dedupe_keep_order
  |> List.filter_map provider_of_string

(* One source for both questions a provider asks about its credential: is it
   there, and what is it. The presence check already read
   [Env_config_core.raw_value_opt], which falls back to the boot-time config
   overrides, while the fetchers read [Sys.getenv_opt], which does not. A key
   declared in runtime.toml therefore made the provider selectable and then
   unusable — the call found nothing (#21972 P2-3). *)
let env_value name =
  Env_config_core.raw_value_opt name |> Fun.flip Option.bind String_util.trim_nonempty

let env_present name = Option.is_some (env_value name)

let provider_has_credentials = function
  | Searxng -> env_present "MASC_SEARXNG_URL"
  | Brave | Brave_llm_context -> env_present "BRAVE_SEARCH_API_KEY"
  | Tavily -> env_present "TAVILY_API_KEY"
  | Exa -> env_present "EXA_API_KEY"
  | Bing_api ->
      env_present "BING_SEARCH_API_KEY" || env_present "AZURE_BING_SEARCH_API_KEY"
  | Ollama -> env_present "OLLAMA_API_KEY"

(* Only credentialed providers search. An empty order is a
   configuration fact and surfaces as an explicit failure in
   [search_impl], never as an empty success.

   [Brave_llm_context] never enters the default order: its grounded
   response shape (context text, no result rows) is a caller choice
   made through provider config, not a fallback. *)
let default_provider_order () =
  [ Searxng; Brave; Tavily; Exa; Bing_api; Ollama ]
  |> List.filter provider_has_credentials

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

(* Grounded envelope: the fetched content lives once in [context_text];
   [sources] carries url/title metadata only. There is deliberately no
   [results] row list — the provider returns chunks, not hits. *)
let render_grounded_context_text ~query items =
  let render_item index { source_url; source_title; snippets } =
    let bullet_lines = List.map (fun snippet -> "- " ^ snippet) snippets in
    String.concat "\n"
      ((Printf.sprintf "%d. %s" (index + 1) source_title)
       :: ("URL: " ^ source_url)
       :: bullet_lines)
  in
  String.concat "\n"
    [ "WebSearch grounded context"
    ; "Query: " ^ query
    ; ""
    ; String.concat "\n\n---\n\n" (List.mapi render_item items)
    ]

let grounded_result_data ~query context =
  let sources =
    context.items
    |> List.map (fun item ->
           `Assoc
             [
               ("url", `String item.source_url);
               ("title", `String item.source_title);
               ("snippet_count", `Int (List.length item.snippets));
             ])
  in
  Tool_args.ok_assoc
    [
      ( "result",
        `Assoc
          [
            ("query", `String query);
            ("engine", `String (provider_to_string Brave_llm_context));
            ("search_url", `String context.context_search_url);
            ("grounded", `Bool true);
            ("result_count", `Int (List.length context.items));
            ("context_text", `String (render_grounded_context_text ~query context.items));
            ("sources", `List sources);
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
  | Error msg -> Error (Config msg)
  | Ok base ->
      let search_url =
        base ^ "/search?q=" ^ Uri.pct_encode query ^ "&format=json"
      in
      match
        Tool_local_runtime_http.http_get_text_with_status ~timeout_sec search_url
      with
      | Error detail ->
          Error (Transport (endpoint_error ~fallback:"search endpoint unavailable" detail))
      | Ok (Some 200, payload) -> Ok (search_url, payload)
      | Ok (Some status, _) ->
          Error (Server (Printf.sprintf "search endpoint returned HTTP %d" status))
      | Ok (None, _) -> Error (Server "search endpoint returned no HTTP status")

let fetch_brave ~timeout_sec ~query ~limit =
  match env_value "BRAVE_SEARCH_API_KEY" with
  | None -> Error (Config "missing BRAVE_SEARCH_API_KEY")
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
          Error (Transport (endpoint_error ~fallback:"provider request failed" detail))
      | Ok (Some 200, payload) ->
          Safe_ops.protect
            ~default:(Error (Parse "provider returned invalid JSON"))
            (fun () ->
              let hits =
                parse_brave_json payload
                |> take_results limit
                |> normalize_hits ~source:(provider_to_string Brave)
              in
              Ok { engine = provider_to_string Brave; search_url; hits })
      | Ok (Some status, _) -> Error (Server (Printf.sprintf "provider returned HTTP %d" status))
      | Ok (None, _) -> Error (Server "provider returned no HTTP status")

let fetch_tavily ~timeout_sec ~query ~limit =
  match env_value "TAVILY_API_KEY" with
  | None -> Error (Config "missing TAVILY_API_KEY")
  | Some api_key ->
      let search_url = "https://api.tavily.com/search" in
      let body_json =
        `Assoc
          [
            ("api_key", `String api_key);
            ("query", `String query);
            ("max_results", `Int limit);
            ("search_depth", `String "basic");
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
          Error (Transport (endpoint_error ~fallback:"provider request failed" detail))
      | Ok (Some 200, payload) ->
          Safe_ops.protect
            ~default:(Error (Parse "provider returned invalid JSON"))
            (fun () ->
              let hits =
                parse_tavily_json payload
                |> take_results limit
                |> normalize_hits ~source:(provider_to_string Tavily)
              in
              Ok { engine = provider_to_string Tavily; search_url; hits })
      | Ok (Some status, _) -> Error (Server (Printf.sprintf "provider returned HTTP %d" status))
      | Ok (None, _) -> Error (Server "provider returned no HTTP status")

let fetch_exa ~timeout_sec ~query ~limit =
  match env_value "EXA_API_KEY" with
  | None -> Error (Config "missing EXA_API_KEY")
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
          Error (Transport (endpoint_error ~fallback:"provider request failed" detail))
      | Ok (Some 200, payload) ->
          Safe_ops.protect
            ~default:(Error (Parse "provider returned invalid JSON"))
            (fun () ->
              let hits =
                parse_exa_json payload
                |> take_results limit
                |> normalize_hits ~source:(provider_to_string Exa)
              in
              Ok { engine = provider_to_string Exa; search_url; hits })
      | Ok (Some status, _) -> Error (Server (Printf.sprintf "provider returned HTTP %d" status))
      | Ok (None, _) -> Error (Server "provider returned no HTTP status")

let fetch_bing_api ~timeout_sec ~query ~limit =
  let api_key =
    match env_value "BING_SEARCH_API_KEY" with
    | Some key -> Some key
    | None -> env_value "AZURE_BING_SEARCH_API_KEY"
  in
  match api_key with
  | None -> Error (Config "missing BING_SEARCH_API_KEY or AZURE_BING_SEARCH_API_KEY")
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
          Error (Transport (endpoint_error ~fallback:"provider request failed" detail))
      | Ok (Some 200, payload) ->
          Safe_ops.protect
            ~default:(Error (Parse "provider returned invalid JSON"))
            (fun () ->
              let hits =
                parse_bing_search_json payload
                |> take_results limit
                |> normalize_hits ~source:(provider_to_string Bing_api)
              in
              Ok { engine = provider_to_string Bing_api; search_url; hits })
      | Ok (Some status, _) -> Error (Server (Printf.sprintf "provider returned HTTP %d" status))
      | Ok (None, _) -> Error (Server "provider returned no HTTP status")

(* Contract:
   https://api-dashboard.search.brave.com/api-reference/summarizer/llm_context/get
   The response token budget is negotiated in the request
   (maximum_number_of_tokens, provider default 8192); [limit] maps to
   maximum_number_of_urls. A valid response with zero grounded items
   stays Ok so the chain records it as "no results". *)
let fetch_brave_llm_context ~timeout_sec ~query ~limit =
  match
    env_value "BRAVE_SEARCH_API_KEY"
  with
  | None -> Error (Config "missing BRAVE_SEARCH_API_KEY")
  | Some api_key ->
      let search_url =
        Printf.sprintf
          "https://api.search.brave.com/res/v1/llm/context?q=%s&maximum_number_of_urls=%d"
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
          Error (Transport (endpoint_error ~fallback:"provider request failed" detail))
      | Ok (Some 200, payload) ->
          Safe_ops.protect
            ~default:(Error (Parse "provider returned invalid JSON"))
            (fun () ->
              Ok
                { context_search_url = search_url
                ; items =
                    parse_brave_llm_context_json payload
                    |> List.map (fun (url, title, snippets) ->
                           { source_url = url; source_title = title; snippets })
                })
      | Ok (Some status, _) -> Error (Server (Printf.sprintf "provider returned HTTP %d" status))
      | Ok (None, _) -> Error (Server "provider returned no HTTP status")

(* Contract: https://docs.ollama.com/capabilities/web-search
   POST /api/web_search with {query, max_results (default 5, max 10)}
   answers {results: [{title, url, content}]}. *)
let fetch_ollama ~timeout_sec ~query ~limit =
  match
    env_value "OLLAMA_API_KEY"
  with
  | None -> Error (Config "missing OLLAMA_API_KEY")
  | Some api_key ->
      let search_url = "https://ollama.com/api/web_search" in
      let body_json =
        `Assoc [ ("query", `String query); ("max_results", `Int limit) ]
        |> Yojson.Safe.to_string
      in
      match
        Tool_local_runtime_http.http_post_json_text_with_status_with_headers
          ~timeout_sec
          ~headers:
            [ ("Accept", "application/json")
            ; ("Authorization", "Bearer " ^ api_key)
            ]
          ~url:search_url
          ~body_json ()
      with
      | Error detail ->
          Error (Transport (endpoint_error ~fallback:"provider request failed" detail))
      | Ok (Some 200, payload) ->
          Safe_ops.protect
            ~default:(Error (Parse "provider returned invalid JSON"))
            (fun () ->
              let hits =
                parse_ollama_search_json payload
                |> take_results limit
                |> normalize_hits ~source:(provider_to_string Ollama)
              in
              Ok { engine = provider_to_string Ollama; search_url; hits })
      | Ok (Some status, _) -> Error (Server (Printf.sprintf "provider returned HTTP %d" status))
      | Ok (None, _) -> Error (Server "provider returned no HTTP status")

let fetch_provider ~query ~limit provider =
  let timeout_sec = Env_config.Tools.web_search_timeout_sec () in
  match provider with
  | Searxng -> (
      match fetch_searxng ~timeout_sec ~query with
      | Error err -> Error err
      | Ok (search_url, payload) ->
          let hits =
            parse_searxng_json payload
            |> take_results limit
            |> normalize_hits ~source:(provider_to_string Searxng)
          in
          Ok (Hits { engine = provider_to_string Searxng; search_url; hits }))
  | Brave ->
      fetch_brave ~timeout_sec ~query ~limit
      |> Result.map (fun response -> Hits response)
  | Brave_llm_context ->
      fetch_brave_llm_context ~timeout_sec ~query ~limit
      |> Result.map (fun context -> Grounded context)
  | Tavily ->
      fetch_tavily ~timeout_sec ~query ~limit
      |> Result.map (fun response -> Hits response)
  | Exa ->
      fetch_exa ~timeout_sec ~query ~limit
      |> Result.map (fun response -> Hits response)
  | Bing_api ->
      fetch_bing_api ~timeout_sec ~query ~limit
      |> Result.map (fun response -> Hits response)
  | Ollama ->
      fetch_ollama ~timeout_sec ~query ~limit
      |> Result.map (fun response -> Hits response)

let cache_key ~query ~limit =
  String.concat "|"
    [ query; Int.to_string limit; String.concat "," (provider_plan ()) ]

type cache_entry = {
  response : Yojson.Safe.t;
  expires_at : float;
}

module Cache_by_key = Set_util.StringMap

let cache_entries = Atomic.make Cache_by_key.empty

let cache_lookup key now =
  let ttl = Env_config.Tools.web_search_cache_ttl_sec () in
  if Stdlib.Float.compare ttl 0.0 <= 0
  then None
  else (
    let rec publish_pruned_snapshot () =
      let current = Atomic.get cache_entries in
      let next =
        Cache_by_key.filter
          (fun _ entry -> Stdlib.Float.compare entry.expires_at now > 0)
          current
      in
      let response =
        Option.map (fun entry -> entry.response) (Cache_by_key.find_opt key next)
      in
      if Atomic.compare_and_set cache_entries current next
      then response
      else publish_pruned_snapshot ()
    in
    publish_pruned_snapshot ())

let cache_store key response now =
  let ttl = Env_config.Tools.web_search_cache_ttl_sec () in
  if Stdlib.Float.compare ttl 0.0 > 0
  then
    Atomic_util.update cache_entries (fun current ->
      Cache_by_key.add key { response; expires_at = now +. ttl } current)

(* Rendered when the provider chain is empty — the operator-facing
   remedy travels with the failure instead of a bare symptom. Shared
   with the test simulator so both boundaries report the same fact. *)
(* Why the chain produced nothing. An empty chain and an exhausted one read
   the same in prose but are not the same failure: nothing was tried in the
   first, so the retry-safety argument below does not apply to it. *)
type search_failure =
  | No_provider_configured
  | All_providers_failed of string

let no_provider_configured_message =
  "no web search provider is configured: set web_search.searxng_url \
   (MASC_SEARXNG_URL) or a provider API key (BRAVE_SEARCH_API_KEY / \
   TAVILY_API_KEY / EXA_API_KEY / BING_SEARCH_API_KEY / OLLAMA_API_KEY)"

let search_impl ~query ~limit =
  let rec loop errors = function
    | [] ->
        Error
          (if Stdlib.List.length errors = 0 then No_provider_configured
           else
             All_providers_failed
               ("all web search providers failed: "
                ^ String.concat "; " (List.rev errors)))
    | provider :: rest -> (
        match fetch_provider ~query ~limit provider with
        | Ok (Hits { hits = _ :: _; _ } as payload) -> Ok payload
        | Ok (Grounded { items = _ :: _; _ } as payload) -> Ok payload
        | Ok (Hits _ | Grounded _) ->
            loop
              (provider_error provider (provider_error_to_string (Parse "no results"))
               :: errors)
              rest
        | Error err ->
            loop (provider_error provider (provider_error_to_string err) :: errors) rest)
  in
  loop [] (provider_order ())

let search_impl_cell = Atomic.make search_impl

let current_search_impl () = Atomic.get search_impl_cell

let with_search_impl_for_test impl f =
  let previous = Atomic.exchange search_impl_cell impl in
  Stdlib.Fun.protect
    ~finally:(fun () -> Atomic.set search_impl_cell previous)
    f

let simulated_search_impl ~outcomes ~query ~limit =
  let normalize source tuples =
    tuples |> take_results limit |> normalize_hits ~source
  in
  let rec loop errors = function
    | [] ->
        Error
          (if Stdlib.List.length errors = 0 then No_provider_configured
           else All_providers_failed (String.concat "; " (List.rev errors)))
    | (provider_name, outcome) :: rest -> (
        match outcome with
        | `Hits hits when Stdlib.List.length hits > 0 ->
            Ok
              (Hits
                 {
                   engine = provider_name;
                   search_url = "test://" ^ provider_name;
                   hits = normalize provider_name hits;
                 })
        | `Grounded ((_ :: _) as entries) ->
            Ok
              (Grounded
                 {
                   context_search_url = "test://" ^ provider_name;
                   items =
                     List.map
                       (fun (url, title, snippets) ->
                         { source_url = url; source_title = title; snippets })
                       entries;
                 })
        | `Hits _ | `Empty | `Grounded [] ->
            loop ((provider_name ^ ": no results") :: errors) rest
        | `Error message ->
            loop ((provider_name ^ ": " ^ message) :: errors) rest)
  in
  loop [] outcomes

let with_simulated_search_for_test ~outcomes f =
  with_search_impl_for_test (simulated_search_impl ~outcomes) f

(* RFC-0189 PR-1b.9 / PR-2 — typed result. Failure-class mapping at the
   handle boundary (source-typed at each construction site; no
   substring matching):

   - [Workflow_rejection]: empty query input.
   - [Dependency_unavailable]: the credentialed chain was empty
     ([No_provider_configured]). Nothing was called, so the
     retry-safety argument below does not reach it: what is
     missing is configuration, and the operator adds it.
   - [Runtime_failure]:    the chain was exhausted
     ([All_providers_failed]). Per-provider transport vs server
     distinction is preserved as typed [provider_error] variants
     ([Transport] / [Server] / [Config] / [Parse]) and rendered
     into the aggregate string via [provider_error_to_string].
     This boundary stays [Runtime_failure] because blind-retry is
     not guaranteed safe (some providers may have returned 4xx).

   The two used to share [Runtime_failure]. A tool that says "it
   crashed" when it means "you have not configured me" tells the
   model to retry something no retry can fix.

   [simulate_for_test] uses the same boundary. *)

let data_ok ~tool_name ~start_time data : Tool_result.result =
  Tool_result.make_ok ~tool_name ~start_time ~data ()

let workflow_err = Tool_result.workflow_err
let runtime_err = Tool_result.runtime_err

(* Nothing was configured to call. The operator adds a provider; the model must
   not treat that as something to try again. *)
let dependency_err ~tool_name ~start_time message =
  Tool_result.error ~failure_class:Tool_result.Dependency_unavailable ~tool_name
    ~start_time message

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
         | Ok payload ->
           let data =
             match payload with
             | Hits response ->
               result_data ~query ~search_url:response.search_url
                 ~engine:response.engine response.hits
             | Grounded context -> grounded_result_data ~query context
           in
           cache_store key data now;
           data_ok ~tool_name ~start_time data
         | Error No_provider_configured ->
             dependency_err ~tool_name ~start_time no_provider_configured_message
         | Error (All_providers_failed detail) ->
             runtime_err ~tool_name ~start_time detail)

let simulate_for_test ~query ~limit outcomes : Tool_result.result =
  match simulated_search_impl ~outcomes ~query ~limit with
  | Ok (Hits response) ->
      data_ok ~tool_name:"masc_web_search" ~start_time:0.0
        (result_data ~query
           ~search_url:response.search_url
           ~engine:response.engine
           response.hits)
  | Ok (Grounded context) ->
      data_ok ~tool_name:"masc_web_search" ~start_time:0.0
        (grounded_result_data ~query context)
  | Error No_provider_configured ->
      dependency_err ~tool_name:"masc_web_search" ~start_time:0.0
        no_provider_configured_message
  | Error (All_providers_failed detail) ->
      runtime_err ~tool_name:"masc_web_search" ~start_time:0.0 detail
