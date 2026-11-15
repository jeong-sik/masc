open Tool_args

(* What an engine wrote in a result row's text field. The engine's own
   parser names it from the field that engine documents, so the meaning
   is fixed where the field is read, never guessed later from the engine's
   name. A missing field is read as an empty text of the same kind. *)
type row_text =
  | Engine_summary of string  (* the engine's own preview of the result *)
  | Engine_text of string     (* text the engine took from the result's page *)

(* [snippet] is the preview of either kind, cleaned and bounded.
   [engine_text] keeps an [Engine_text] whole, trimmed only, so a page
   that cannot be fetched still has the text the engine gave for it. *)
type normalized_hit = {
  title : string;
  url : string;
  snippet : string;
  engine_text : string option;
  source : string;
  rank : int;
  published_at : string option;
}

type provider = Web_search_provider.t =
  | Searxng
  | Brave
  | Brave_llm_context
  | Tavily
  | Exa
  | Bing_api
  | Ollama
  | Zai

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
  | Account_refused of Runtime_account_access.refusal
      (* the process does not send with the keys of its host *)

let provider_error_to_string = function
  | Transport msg -> "transport: " ^ msg
  | Server msg -> "server: " ^ msg
  | Config msg -> "config: " ^ msg
  | Parse msg -> "parse: " ^ msg
  | Account_refused refusal -> "account: " ^ Runtime_account_access.refusal_to_string refusal

type simulated_provider_outcome =
  [ `Error of string
  | `Empty
  | `Hits of (string * string * string) list
  | `Grounded of (string * string * string list) list
  | `Brave_body of string
  | `Ollama_body of string
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

open Result.Syntax

(* A provider's empty answer is data. Missing arrays and malformed responses
   must stay failures; otherwise a broken endpoint becomes a cached no-hit
   answer. Error messages deliberately omit the response body. *)
let parse_result_array ~path payload =
  let rec field_at_path json = function
    | [] ->
        (match json with
         | `List items -> Ok items
         | _ -> Error (Parse "provider result field is not an array"))
    | key :: rest ->
        (match Json_util.assoc_member_opt key json with
         | Some value -> field_at_path value rest
         | None -> Error (Parse "provider response is missing its result array"))
  in
  match Yojson.Safe.from_string payload with
  | json -> field_at_path json path
  | exception Yojson.Json_error _ -> Error (Parse "provider returned invalid JSON")

let usable_results original parsed =
  match original, parsed with
  | [], [] -> Ok []
  | _ :: _, [] -> Error (Parse "provider returned no usable result entries")
  | _, _ :: _ -> Ok parsed

let string_field item key =
  match Json_util.assoc_member_opt key item with
  | Some (`String value) -> String_util.trim_nonempty value
  | _ -> None

let summary text = Engine_summary text
let engine_text text = Engine_text text

(* [text] names what the engine puts in [text_field]. *)
let parse_json_search_results ?(url_field = "url") ~results_path ~title_field ~text_field
    ~text payload =
  let* items = parse_result_array ~path:results_path payload in
  let parsed =
    List.filter_map
      (fun item ->
        match string_field item title_field, string_field item url_field with
        | Some title, Some url when valid_search_result_url url ->
            let row_text =
              match string_field item text_field with
              | Some value -> value
              | None -> ""
            in
            Some (title, url, text row_text)
        | _ -> None)
      items
  in
  usable_results items parsed

let parse_searxng_json payload =
  let* hits = parse_json_search_results ~results_path:["results"]
      ~title_field:"title" ~text_field:"content" ~text:summary payload in
  match hits with
  | _ :: _ -> Ok hits
  | [] ->
      (* SearxNG can answer HTTP 200 with no hits when its engines failed.
         That is not evidence of a successful empty search. JSON syntax was
         validated by the parser above. *)
      match Json_util.assoc_member_opt "unresponsive_engines"
              (Yojson.Safe.from_string payload) with
      | None | Some (`List []) -> Ok []
      | Some (`List (_ :: _)) -> Error (Server "search engines unavailable")
      | Some _ -> Error (Parse "provider unresponsive_engines field is not an array")

(* Brave's Web Search 200 body declares [web] as a nullable object; only
   inside that object is [results] required. A search envelope
   ([type = "search"]) whose [web] is null or absent is Brave's answer for a
   query with no web hits, so it is an empty answer. Anything else keeps the
   #39802 rule: a body we cannot read as that envelope is a failure, never a
   cached no-hit answer.
   https://api-dashboard.search.brave.com/api-reference/web/search/get *)
let parse_brave_json payload =
  match Yojson.Safe.from_string payload with
  | exception Yojson.Json_error _ -> Error (Parse "provider returned invalid JSON")
  | `Assoc _ as root ->
      (match Json_util.assoc_member_opt "web" root with
       | Some (`Assoc _) ->
           parse_json_search_results ~results_path:["web"; "results"]
             ~title_field:"title" ~text_field:"description" ~text:summary payload
       | None | Some `Null ->
           (match Json_util.assoc_member_opt "type" root with
            | Some (`String "search") -> Ok []
            | _ -> Error (Parse "provider response is missing its result array"))
       | Some _ -> Error (Parse "provider web field is not an object"))
  | _ -> Error (Parse "provider response is not a JSON object")

(* At the [search_depth] [fetch_tavily] asks for, Tavily's [content] is
   "multiple semantically relevant snippets per URL": chunks of about 500
   characters "pulled directly from the source", joined as
   "<chunk 1> [...] <chunk 2>". The whole page is [raw_content], sent only
   when the request asks for it, and [fetch_tavily] does not. Only the
   [ultra-fast] depth answers with "one NLP summary per URL".
   https://docs.tavily.com/documentation/api-reference/endpoint/search *)
let tavily_search_depth = "basic"

let parse_tavily_json payload =
  parse_json_search_results ~results_path:["results"]
    ~title_field:"title" ~text_field:"content" ~text:engine_text payload

(* Ollama's [content] is "relevant content snippet from the web page": text
   taken from the page, not the page's main content, which [web_fetch]
   answers with. https://docs.ollama.com/capabilities/web-search *)
let parse_ollama_search_json payload =
  parse_json_search_results ~results_path:["results"]
    ~title_field:"title" ~text_field:"content" ~text:engine_text payload

(* Exa's [text] is "The full content text of the search result", sent when
   the request asks for it with [contents.text]. [fetch_exa] does not ask,
   so its rows carry no [text] today.
   https://github.com/exa-labs/openapi-spec (SearchResultOutput.text) *)
let parse_exa_json payload =
  parse_json_search_results ~results_path:["results"]
    ~title_field:"title" ~text_field:"text" ~text:engine_text payload

(* z.ai's search tool answers with one text block, and that text is the
   result array serialised twice: a JSON string whose content is the array.
   An array that is not nested is read the same, since both spell the same
   data. The link is under "link" and the snippet under "content".
   https://docs.z.ai/devpack/mcp/search-mcp-server *)
let parse_zai_search_text text =
  let rows payload =
    parse_json_search_results ~url_field:"link" ~results_path:[] ~title_field:"title"
      ~text_field:"content" ~text:summary payload
  in
  match Yojson.Safe.from_string text with
  | exception Yojson.Json_error _ -> Error (Parse "provider returned invalid JSON")
  | `String nested -> rows nested
  | `List _ -> rows text
  | _ -> Error (Parse "provider response is not a result array")

let parse_bing_search_json payload =
  parse_json_search_results ~results_path:["webPages"; "value"]
    ~title_field:"name" ~text_field:"snippet" ~text:summary payload

let parse_brave_llm_context_json payload =
  let* items = parse_result_array ~path:["grounding"; "generic"] payload in
  let parsed =
    List.filter_map
      (fun entry ->
        let snippets =
          match Json_util.assoc_member_opt "snippets" entry with
          | Some (`List entries) ->
              List.filter_map
                (function
                  | `String snippet -> String_util.trim_nonempty snippet
                  | _ -> None)
                entries
          | _ -> []
        in
        match string_field entry "url", snippets with
        | Some url, _ :: _ when valid_search_result_url url ->
            let title =
              match string_field entry "title" with
              | Some title -> title
              | None -> url
            in
            Some (url, title, snippets)
        | _ -> None)
      items
  in
  usable_results items parsed

let provider_to_string = Web_search_provider.label

let provider_of_string = Web_search_provider.of_label

let parse_provider_csv raw =
  raw
  |> String.split_on_char ','
  |> List.filter_map provider_of_string
  |> List.map provider_to_string
  |> Json_util.dedupe_keep_order
  |> List.filter_map provider_of_string

(* One source for both questions a provider asks about its credential: is it
   there, and what is it. [Web_search_provider] answers both from the same
   variable names, through [Env_config_core.raw_value_opt], which falls back to
   the boot-time config overrides. The presence check and the fetchers once
   read different paths, so a key declared in runtime.toml made the provider
   selectable and then unusable — the call found nothing (#21972 P2-3).
   [masc web-search-setup] reports credentials through the same table. *)
let provider_has_credentials = Web_search_provider.has_credentials

(* HIGH-RISK-UNREVIEWED: the credential a fetcher sends, looked up through the
   table that admitted the provider, so the variable a failure names is the
   one that was read. The key is an account of the host, so it is read only
   with the proof that the access shares the accounts of the host (plan
   D4d). *)
let credential (_ : Runtime_account_access.host_account) provider =
  match Web_search_provider.credential provider with
  | Some value -> Ok value
  | None ->
      Error
        (Config
           ("missing "
            ^ String.concat " or "
                (Web_search_provider.credential_env_names provider)))

(* Only credentialed providers search. An empty order is a
   configuration fact and surfaces as an explicit failure in
   [search_impl], never as an empty success.

   [Brave_llm_context] never enters the default order: its grounded
   response shape (context text, no result rows) is a caller choice
   made through provider config, not a fallback
   ([Web_search_provider.default_order]). *)
let default_provider_order () =
  Web_search_provider.default_order
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

(* A snippet is the preview a caller picks results by. An [Engine_text] is
   read as the snippet too. The bound sits above the longest snippet an
   engine writes itself, so those pass whole and only engine text is cut.
   It counts bytes, marker included, so a CJK snippet is cut at about a
   third as many characters. The whole engine text stays on the hit for
   [includeContent], capped there by [contentMaxChars]. *)
let snippet_max_bytes = 1024
let snippet_cut_marker = "…"

let bound_snippet snippet =
  String_util.utf8_safe ~max_bytes:snippet_max_bytes ~suffix:snippet_cut_marker snippet
  |> String_util.to_string

let normalize_hits ~source rows =
  rows
  |> List.filter (fun (title, url, _text) -> not (String.equal title "") && valid_search_result_url url)
  |> List.mapi (fun idx (title, url, text) ->
         let preview, engine_text =
           match text with
           | Engine_summary summary -> (summary, None)
           | Engine_text page_text -> (page_text, String_util.trim_nonempty page_text)
         in
         {
           title;
           url;
           snippet = clean_search_text preview |> bound_snippet;
           engine_text;
           source;
           rank = idx + 1;
           published_at = None;
         })

let result_object ~query ~search_url ~engine hits =
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
  `Assoc
    [
      ("query", `String query);
      ("engine", `String engine);
      ("search_url", `String search_url);
      ("result_count", `Int (List.length hits));
      ("results", `List results);
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

let grounded_result_object ~query context =
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
  `Assoc
    [
      ("query", `String query);
      ("engine", `String (provider_to_string Brave_llm_context));
      ("search_url", `String context.context_search_url);
      ("grounded", `Bool true);
      ("result_count", `Int (List.length context.items));
      ("context_text", `String (render_grounded_context_text ~query context.items));
      ("sources", `List sources);
    ]

(* One provider's failed attempt in the chain. [provider] is the provider
   name and [detail] its classified failure, e.g. "transport: ...". *)
type provider_failure = { provider : string; detail : string }

let provider_failure_to_string failure =
  Printf.sprintf "%s: %s" failure.provider failure.detail

(** Truncate transport errors before the " for " suffix that usually prefixes
    the request URL, so provider failure messages keep the useful curl detail
    without echoing search queries or other URL payloads. *)
let redact_transport_error_detail message =
  match String_util.find_substring message " for " with
  | Some idx -> String.sub message 0 idx
  | None -> message

let endpoint_error ~fallback detail =
  let detail = redact_transport_error_detail detail |> String.trim in
  if String.equal detail "" then fallback else Printf.sprintf "%s (%s)" fallback detail

let fetch_searxng ~timeout_sec ~query =
  match Env_config_runtime.Tools.searxng_base_url () with
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

(* The two failures a provider call has on any wire: the request did not
   complete, or the endpoint answered with a status. The transport's own
   detail is redacted because it can echo the query. *)
let provider_transport_error detail =
  Transport (endpoint_error ~fallback:"provider request failed" detail)

let provider_http_status_error status =
  Server (Printf.sprintf "provider returned HTTP %d" status)

(* Every provider fetch except SearXNG's settles its HTTP outcome the same way:
   a transport failure, a status other than 200, no status at all, or the 200
   body handed to [on_ok]. *)
let settle_provider_response ~on_ok = function
  | Error detail -> Error (provider_transport_error detail)
  | Ok (Some 200, payload) -> on_ok payload
  | Ok (Some status, _) -> Error (provider_http_status_error status)
  | Ok (None, _) -> Error (Server "provider returned no HTTP status")

(* The response of [provider] for a parsed hit list: at most [limit] hits, each
   normalised under the provider's label. *)
let response_of_parsed provider ~search_url ~limit parsed =
  let engine = provider_to_string provider in
  let hits = parsed |> take_results limit |> normalize_hits ~source:engine in
  Ok { engine; search_url; hits }

(* One path from a Brave 200 body to a response, shared by [fetch_brave] and
   the simulator's [`Brave_body] outcome so tests exercise the real parse. *)
let brave_response_of_body ~search_url ~limit payload =
  let* parsed = parse_brave_json payload in
  response_of_parsed Brave ~search_url ~limit parsed

let fetch_brave ~host ~timeout_sec ~query ~limit =
  match credential host Brave with
  | Error error -> Error error
  | Ok api_key ->
      let search_url =
        Printf.sprintf
          "https://api.search.brave.com/res/v1/web/search?q=%s&count=%d"
          (Uri.pct_encode query) limit
      in
      Tool_local_runtime_http.http_get_text_with_status_with_headers
        ~timeout_sec
        ~headers:
          [ ("Accept", "application/json"); ("X-Subscription-Token", api_key) ]
        search_url
      |> settle_provider_response
           ~on_ok:(brave_response_of_body ~search_url ~limit)

let fetch_tavily ~host ~timeout_sec ~query ~limit =
  match credential host Tavily with
  | Error error -> Error error
  | Ok api_key ->
      let search_url = "https://api.tavily.com/search" in
      let body_json =
        `Assoc
          [
            ("api_key", `String api_key);
            ("query", `String query);
            ("max_results", `Int limit);
            ("search_depth", `String tavily_search_depth);
          ]
        |> Yojson.Safe.to_string
      in
      Tool_local_runtime_http.http_post_json_text_with_status_with_headers
        ~timeout_sec
        ~headers:[ ("Accept", "application/json") ]
        ~url:search_url
        ~body_json ()
      |> settle_provider_response ~on_ok:(fun payload ->
             let* parsed = parse_tavily_json payload in
             response_of_parsed Tavily ~search_url ~limit parsed)

let fetch_exa ~host ~timeout_sec ~query ~limit =
  match credential host Exa with
  | Error error -> Error error
  | Ok api_key ->
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
      Tool_local_runtime_http.http_post_json_text_with_status_with_headers
        ~timeout_sec
        ~headers:
          [ ("Accept", "application/json"); ("x-api-key", api_key) ]
        ~url:search_url
        ~body_json ()
      |> settle_provider_response ~on_ok:(fun payload ->
             let* parsed = parse_exa_json payload in
             response_of_parsed Exa ~search_url ~limit parsed)

let fetch_bing_api ~host ~timeout_sec ~query ~limit =
  match credential host Bing_api with
  | Error error -> Error error
  | Ok key ->
      let search_url =
        Printf.sprintf
          "https://api.bing.microsoft.com/v7.0/search?q=%s&count=%d&responseFilter=Webpages"
          (Uri.pct_encode query) limit
      in
      Tool_local_runtime_http.http_get_text_with_status_with_headers
        ~timeout_sec
        ~headers:
          [
            ("Accept", "application/json");
            ("Ocp-Apim-Subscription-Key", key);
          ]
        search_url
      |> settle_provider_response ~on_ok:(fun payload ->
             let* parsed = parse_bing_search_json payload in
             response_of_parsed Bing_api ~search_url ~limit parsed)

(* Contract:
   https://api-dashboard.search.brave.com/api-reference/summarizer/llm_context/get
   The response token budget is negotiated in the request
   (maximum_number_of_tokens, provider default 8192); [limit] maps to
   maximum_number_of_urls. A valid response with zero grounded items
   stays Ok so the chain records it as "no results". *)
let fetch_brave_llm_context ~host ~timeout_sec ~query ~limit =
  match credential host Brave_llm_context with
  | Error error -> Error error
  | Ok api_key ->
      let search_url =
        Printf.sprintf
          "https://api.search.brave.com/res/v1/llm/context?q=%s&maximum_number_of_urls=%d"
          (Uri.pct_encode query) limit
      in
      Tool_local_runtime_http.http_get_text_with_status_with_headers
        ~timeout_sec
        ~headers:
          [ ("Accept", "application/json"); ("X-Subscription-Token", api_key) ]
        search_url
      |> settle_provider_response ~on_ok:(fun payload ->
             let* parsed = parse_brave_llm_context_json payload in
             Ok
               { context_search_url = search_url
               ; items = List.map (fun (url, title, snippets) ->
                     { source_url = url; source_title = title; snippets }) parsed
               })

(* One path from an Ollama 200 body to a response, shared by [fetch_ollama]
   and the simulator's [`Ollama_body] outcome so tests exercise the real
   parse. *)
let ollama_response_of_body ~search_url ~limit payload =
  let* parsed = parse_ollama_search_json payload in
  response_of_parsed Ollama ~search_url ~limit parsed

(* Contract: https://docs.ollama.com/capabilities/web-search
   POST /api/web_search with {query, max_results (default 5, max 10)}
   answers {results: [{title, url, content}]}. *)
let fetch_ollama ~host ~timeout_sec ~query ~limit =
  match credential host Ollama with
  | Error error -> Error error
  | Ok api_key ->
      let search_url = "https://ollama.com/api/web_search" in
      let body_json =
        `Assoc [ ("query", `String query); ("max_results", `Int limit) ]
        |> Yojson.Safe.to_string
      in
      Tool_local_runtime_http.http_post_json_text_with_status_with_headers
        ~timeout_sec
        ~headers:
          [ ("Accept", "application/json")
          ; ("Authorization", "Bearer " ^ api_key)
          ]
        ~url:search_url
        ~body_json ()
      |> settle_provider_response ~on_ok:(ollama_response_of_body ~search_url ~limit)

(* z.ai's Web Search MCP server: streamable HTTP, the key as a Bearer token,
   one tool. The tool's own description (tools/list, measured 2026-10-14)
   gives [location] as "cn" by default, the Chinese region, or "us", the
   non-Chinese region, which is what an operator outside China wants. The
   documentation page names the server and the plan but not these
   arguments, and spells the tool [webSearchPrime].
   https://docs.z.ai/devpack/mcp/search-mcp-server *)
let zai_mcp_url = "https://api.z.ai/api/mcp/web_search_prime/mcp"
let zai_search_tool = "web_search_prime"
let zai_location = "us"

(* What an MCP failure says to the chain. The server's own message is left
   out, as for the other providers: it can echo the query. *)
let rec zai_error_of_mcp : Mcp_client.error -> provider_error = function
  | Mcp_client.Transport detail -> provider_transport_error detail
  | Mcp_client.Unauthorized _ -> Server "provider refused the key"
  | Mcp_client.Http { status; _ } -> provider_http_status_error status
  | Mcp_client.Rpc { code; _ } -> Server (Printf.sprintf "provider refused the call (%d)" code)
  | Mcp_client.Input_required _ -> Server "provider requires additional input"
  | Mcp_client.Before_tool_call error -> zai_error_of_mcp error
  | Mcp_client.Malformed _ -> Parse "provider returned an unreadable MCP answer"

(* z.ai reports an API-level failure as HTTP 200 with a body like
   {"code":401,"msg":"token expired or incorrect","success":false}, which the
   MCP transport would read as an answer that is not JSON-RPC and call
   malformed. The code is the status the failure means, so it is put on the
   response: a refused key is then a refused key. Seen on 2026-10-14 with an
   invalid key; a streamed answer is not JSON and passes through. *)
let lift_zai_failure_code ~refused (post : Mcp_client.post) : Mcp_client.post =
 { post with send = (fun ~deadline ~url ~headers ~body ->
  match post.send ~deadline ~url ~headers ~body with
  | Error _ as error -> error
  | Ok ({ Masc_http_client.status = 200; body = reply; _ } as response) ->
      (match Yojson.Safe.from_string reply with
       | `Assoc fields ->
           let code =
             match List.assoc_opt "code" fields with
             | Some (`Int code) -> Some code
             | Some (`String text) -> int_of_string_opt (String.trim text)
             | _ -> None
           in
           (match List.assoc_opt "success" fields, code with
            | Some (`Bool false), Some code ->
                (* A business code (the balance or quota ones are not HTTP
                   statuses) cannot be a status; it is kept for the error the
                   transport will report as an unreadable answer. *)
                refused := Some code;
                if code >= 400 && code <= 599
                then Ok { response with Masc_http_client.status = code }
                else Ok response
            | _ -> Ok response)
       | _ -> Ok response
       | exception Yojson.Json_error _ -> Ok response)
  | Ok response -> Ok response) }

(* The session and the call, over a transport the caller supplies so a test can
   answer both. [initialize], the [initialized] notification and the
   [tools/call] are three requests; the session id the first returns rides on
   the others. Handshake requests have their own windows. Catalog pages and
   the tool request share one provider timeout. *)
let search_via_zai ~post ~api_key ~query ~limit =
  let refused = ref None in
  let post = lift_zai_failure_code ~refused post in
  let search_url = zai_mcp_url in
  (* An answer that is not JSON-RPC but is a refusal z.ai put a code on is a
     refusal, not an unreadable answer. *)
  let zai_error_of_mcp error =
    match error with
    | Mcp_client.Malformed _ ->
        (match !refused with
         | Some code -> Server (Printf.sprintf "provider refused the call (%d)" code)
         | None -> zai_error_of_mcp error)
    | Mcp_client.Transport _ | Mcp_client.Unauthorized _ | Mcp_client.Http _
    | Mcp_client.Rpc _ | Mcp_client.Input_required _ | Mcp_client.Before_tool_call _ -> zai_error_of_mcp error
  in
  match Mcp_client.connect ~post ~url:zai_mcp_url ~access_token:api_key () with
  | Error error -> Error (zai_error_of_mcp error)
  | Ok session ->
      (match
         Mcp_client.call_tool ~post session ~name:zai_search_tool
           ~arguments:
             (`Assoc
               [ ("search_query", `String query); ("location", `String zai_location) ])
       with
       | Error error -> Error (zai_error_of_mcp error)
       | Ok { Mcp_client.is_error = true; _ } -> Error (Server "provider reported a failed search")
       | Ok { Mcp_client.text; structured_content; _ } ->
           let text =
             match text, structured_content with
             | "", Some value -> Yojson.Safe.to_string value
             | text, _ -> text
           in
           let* parsed = parse_zai_search_text text in
           let hits =
             parsed |> take_results limit
             |> normalize_hits ~source:(provider_to_string Zai)
           in
           Ok { engine = provider_to_string Zai; search_url; hits })

let search_via_zai_for_test ~post ~api_key ~query ~limit =
  search_via_zai ~post ~api_key ~query ~limit
  |> Result.map (fun response ->
         List.map (fun hit -> (hit.title, hit.url, hit.snippet)) response.hits)

(* The same curl the other providers use, so the fetch runs wherever theirs do.
   The one header the helper writes itself is dropped from the client's list.
   [run] is the helper, passed in so a test sees what it is given. *)
let curl_mcp_post_with ~run ~timeout_sec : Mcp_client.post =
 { deadline_s = float_of_int (max 1 timeout_sec)
 ; send = (fun ~deadline ~url ~headers ~body ->
  let headers =
    List.filter
      (fun (name, _) -> not (String.equal (String.lowercase_ascii name) "content-type"))
      headers
  in
  match run ~deadline ~timeout_sec ~headers ~url ~body_json:body () with
  | Error detail -> Error detail
  | Ok { Tool_local_runtime_http.status; headers; body } ->
      Ok { Masc_http_client.status; headers; body }) }

let curl_mcp_post ~timeout_sec =
  curl_mcp_post_with
    ~run:(fun ~deadline ~timeout_sec ~headers ~url ~body_json () ->
      Tool_local_runtime_http.http_post_json_response_with_headers ~deadline ~timeout_sec ~headers ~url
        ~body_json ())
    ~timeout_sec

let curl_mcp_post_with_for_test = curl_mcp_post_with

let fetch_zai ~host ~timeout_sec ~query ~limit =
  match credential host Zai with
  | Error error -> Error error
  | Ok api_key ->
      search_via_zai ~post:(curl_mcp_post ~timeout_sec) ~api_key ~query ~limit

(* [host] is the access the search took once. A provider that needs a key is
   called only with its proof; SearXNG needs none. *)
let fetch_provider ~host ~query ~limit provider =
  let timeout_sec = Env_config.Tools.web_search_timeout_sec () in
  let keyed fetch =
    match host with
    | Error refusal -> Error (Account_refused refusal)
    | Ok host -> fetch host
  in
  match provider with
  | Searxng -> (
      match fetch_searxng ~timeout_sec ~query with
      | Error err -> Error err
      | Ok (search_url, payload) ->
          let* parsed = parse_searxng_json payload in
          let hits =
            parsed |> take_results limit
            |> normalize_hits ~source:(provider_to_string Searxng)
          in
          Ok (Hits { engine = provider_to_string Searxng; search_url; hits }))
  | Brave ->
      keyed (fun host -> fetch_brave ~host ~timeout_sec ~query ~limit)
      |> Result.map (fun response -> Hits response)
  | Brave_llm_context ->
      keyed (fun host -> fetch_brave_llm_context ~host ~timeout_sec ~query ~limit)
      |> Result.map (fun context -> Grounded context)
  | Tavily ->
      keyed (fun host -> fetch_tavily ~host ~timeout_sec ~query ~limit)
      |> Result.map (fun response -> Hits response)
  | Exa ->
      keyed (fun host -> fetch_exa ~host ~timeout_sec ~query ~limit)
      |> Result.map (fun response -> Hits response)
  | Bing_api ->
      keyed (fun host -> fetch_bing_api ~host ~timeout_sec ~query ~limit)
      |> Result.map (fun response -> Hits response)
  | Ollama ->
      keyed (fun host -> fetch_ollama ~host ~timeout_sec ~query ~limit)
      |> Result.map (fun response -> Hits response)
  | Zai ->
      keyed (fun host -> fetch_zai ~host ~timeout_sec ~query ~limit)
      |> Result.map (fun response -> Hits response)

let cache_key ~query ~limit =
  String.concat "|"
    [ query; Int.to_string limit; String.concat "," (provider_plan ()) ]

(* One answered search, shaped once for both callers. [data] is the tool
   envelope [handle] returns. The Lane Add-on port reads the other fields, so
   a cache hit and a fresh answer carry the same serving provider, failures
   and search data. [payload] is what [data] was rendered from; a cache hit
   keeps it, so the rows' engine text survives the cache. *)
type answer = {
  data : Yojson.Safe.t;
  serving_provider : string;
  failures : provider_failure list;
  search : Yojson.Safe.t;
  payload : search_payload;
}

let answer_of ~query (payload, failures) =
  let serving_provider, search =
    match payload with
    | Hits response ->
        ( response.engine,
          result_object ~query ~search_url:response.search_url
            ~engine:response.engine response.hits )
    | Grounded context ->
        ( provider_to_string Brave_llm_context,
          grounded_result_object ~query context )
  in
  let envelope = Tool_args.ok_assoc [ ("result", search) ] in
  let data =
    match envelope, failures with
    | `Assoc fields, _ :: _ ->
        `Assoc
          (( "provider_errors",
             `List
               (List.map
                  (fun failure -> `String (provider_failure_to_string failure))
                  failures) )
           :: fields)
    | _, [] -> envelope
    | _, _ :: _ -> envelope
  in
  { data; serving_provider; failures; search; payload }

type cache_entry = {
  answer : answer;
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
      let answer =
        Option.map (fun entry -> entry.answer) (Cache_by_key.find_opt key next)
      in
      if Atomic.compare_and_set cache_entries current next
      then answer
      else publish_pruned_snapshot ()
    in
    publish_pruned_snapshot ())

let cache_store key answer now =
  let ttl = Env_config.Tools.web_search_cache_ttl_sec () in
  if Stdlib.Float.compare ttl 0.0 > 0
  then
    Atomic_util.update cache_entries (fun current ->
      Cache_by_key.add key { answer; expires_at = now +. ttl } current)

(* Rendered when the provider chain is empty — the operator-facing
   remedy travels with the failure instead of a bare symptom. Shared
   with the test simulator so both boundaries report the same fact. *)
(* Why the chain produced nothing. An empty chain and an exhausted one read
   the same in prose but are not the same failure: nothing was tried in the
   first, so the retry-safety argument below does not apply to it. *)
type search_failure =
  | No_provider_configured
  | All_providers_failed of string
  | Host_keys_refused of Runtime_account_access.refusal
      (* The process sends nothing with the keys of its host, and the
         provider order holds no provider that needs none. *)

let no_provider_configured_message =
  let names =
    Web_search_provider.default_order
    |> List.concat_map Web_search_provider.credential_env_names
  in
  Printf.sprintf
    "no web search provider is configured: set one of %s where the server \
     starts (web_search.searxng_url in runtime.toml also sets \
     MASC_SEARXNG_URL). `masc web-search-setup` shows what each provider needs."
    (String.concat " / " names)

(* Keep trying after an empty response so later providers may supply hits.
   If none does, the first valid empty response still answers the query.
   Failed providers remain visible in the result instead of turning that
   answer into a runtime failure. Production and simulation share this loop. *)
let search_chain ~fetch providers =
  let rec loop first_empty failures = function
    | [] ->
        (match first_empty, failures with
         | Some payload, _ -> Ok (payload, List.rev failures)
         | None, [] -> Error No_provider_configured
         | None, _ :: _ ->
             Error (All_providers_failed
               ("all web search providers failed: "
                ^ String.concat "; "
                    (List.rev_map provider_failure_to_string failures))))
    | provider :: rest ->
        match fetch provider with
        | Ok (Hits { hits = _ :: _; _ } as payload)
        | Ok (Grounded { items = _ :: _; _ } as payload) ->
            Ok (payload, List.rev failures)
        | Ok (Hits _ | Grounded _ as payload) ->
            let first_empty =
              match first_empty with
              | Some _ -> first_empty
              | None -> Some payload
            in
            loop first_empty failures rest
        | Error failure -> loop first_empty (failure :: failures) rest
  in
  loop None [] providers

(* A multi-account process sends nothing with the keys of its host (plan
   D4d). It still asks a provider without a key; a provider with one fails in
   the chain with the refusal, so a served answer lists it in its errors.
   When no provider of the order can answer there, the search ends with the
   refusal, not with the chain's failures. *)
let search_impl ~query ~limit =
  let host = Runtime_account_access.authorize_host Runtime_account_access.Web_search in
  let providers = provider_order () in
  let keyless provider = not (Web_search_provider.needs_credential_to_call provider) in
  match host with
  | Error refusal when not (List.exists keyless providers) -> Error (Host_keys_refused refusal)
  | Ok _ | Error _ ->
      search_chain providers
        ~fetch:(fun provider ->
          fetch_provider ~host ~query ~limit provider
          |> Result.map_error (fun error ->
              { provider = provider_to_string provider
              ; detail = provider_error_to_string error }))

let search_impl_cell = Atomic.make search_impl

let current_search_impl () = Atomic.get search_impl_cell

let with_search_impl_for_test impl f =
  let previous = Atomic.exchange search_impl_cell impl in
  Stdlib.Fun.protect
    ~finally:(fun () -> Atomic.set search_impl_cell previous)
    f

let simulated_search_impl ~outcomes ~query:_ ~limit =
  search_chain outcomes ~fetch:(fun (provider_name, outcome) ->
    let hits_payload rows =
      Hits
        { engine = provider_name
        ; search_url = "test://" ^ provider_name
        ; hits = rows |> take_results limit |> normalize_hits ~source:provider_name
        }
    in
    let parsed_body response_of_body body =
      response_of_body ~search_url:("test://" ^ provider_name) ~limit body
      |> Result.map (fun response -> Hits response)
      |> Result.map_error (fun error ->
          { provider = provider_name; detail = provider_error_to_string error })
    in
    match outcome with
    | `Hits hits ->
        Ok (hits_payload
              (List.map (fun (title, url, snippet) -> (title, url, Engine_summary snippet)) hits))
    | `Empty -> Ok (hits_payload [])
    | `Grounded entries ->
        Ok (Grounded
          { context_search_url = "test://" ^ provider_name
          ; items = List.map (fun (url, title, snippets) ->
                { source_url = url; source_title = title; snippets }) entries
          })
    | `Brave_body body -> parsed_body brave_response_of_body body
    | `Ollama_body body -> parsed_body ollama_response_of_body body
    | `Error message -> Error { provider = provider_name; detail = message })

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

   - [Policy_rejection]: the process sends nothing with the keys of
     its host and no provider of the order needs none
     ([Host_keys_refused]). The same search stays refused.

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

let host_keys_refused_message refusal =
  Printf.sprintf
    "%s. Only a provider without a key searches in this process: SearXNG \
     (MASC_SEARXNG_URL). `masc web-search-setup` shows what each provider needs."
    (Runtime_account_access.refusal_to_string refusal)

let failure_message = function
  | No_provider_configured -> no_provider_configured_message
  | All_providers_failed detail -> detail
  | Host_keys_refused refusal -> host_keys_refused_message refusal

(* One boundary for the tool and its simulator. *)
let failure_result ~tool_name ~start_time failure =
  let message = failure_message failure in
  match failure with
  | No_provider_configured -> dependency_err ~tool_name ~start_time message
  | All_providers_failed _ -> runtime_err ~tool_name ~start_time message
  | Host_keys_refused _ ->
      Tool_result.error ~failure_class:Tool_result.Policy_rejection ~tool_name ~start_time
        message

(* The served envelope, after [on_rows] has read the rows it was rendered
   from. A grounded answer has no rows and is served as it is. *)
let served_data ~on_rows answer =
  match answer.payload with
  | Hits response -> on_rows response.hits answer.data
  | Grounded _ -> answer.data

let handle_with_rows ~on_rows ~tool_name ~start_time args : Tool_result.result =
  let query = get_string args "query" "" in
  match validate_query query with
  | Error message -> workflow_err ~tool_name ~start_time message
  | Ok query ->
      let limit = max 1 (min 10 (get_int args "limit" 5)) in
      let now = Unix.gettimeofday () in
      let key = cache_key ~query ~limit in
      match cache_lookup key now with
      | Some cached -> data_ok ~tool_name ~start_time (served_data ~on_rows cached)
      | None ->
        (match (current_search_impl ()) ~query ~limit with
         | Ok response ->
           let answer = answer_of ~query response in
           cache_store key answer now;
           data_ok ~tool_name ~start_time (served_data ~on_rows answer)
         | Error failure -> failure_result ~tool_name ~start_time failure)

let handle ~tool_name ~start_time args =
  handle_with_rows ~on_rows:(fun _rows data -> data) ~tool_name ~start_time args

(* Lane Add-on web-search port (task-2527 E11): the secret-free projection of
   the same chain the tool dispatches. Validation, cache identity/window and
   the provider fallback plan are exactly the tool's — the port documents that
   parity — and the envelope carries the serving provider's own typed result
   data, its name and the per-provider errors the chain kept. No credential,
   key or cache key crosses into the envelope. *)
let addon_search_runner ~query ~limit =
  match validate_query query with
  | Error message -> Error message
  | Ok query ->
    let limit = max 1 (min 10 (match limit with Some limit -> limit | None -> 5)) in
    let now = Unix.gettimeofday () in
    let key = cache_key ~query ~limit in
    let envelope answer =
      { Lane_addon_search_result.serving_provider = Some answer.serving_provider;
        provider_errors =
          List.map
            (fun failure -> (failure.provider, String.trim failure.detail))
            answer.failures;
        search = answer.search } in
    match cache_lookup key now with
    | Some cached -> Ok (envelope cached)
    | None ->
        (match (current_search_impl ()) ~query ~limit with
         | Ok response ->
             let answer = answer_of ~query response in
             cache_store key answer now;
             Ok (envelope answer)
         | Error failure -> Error (failure_message failure))

let simulate_for_test ~query ~limit outcomes : Tool_result.result =
  let start_time = Tool_timing.start () in
  match simulated_search_impl ~outcomes ~query ~limit with
  | Ok response ->
      data_ok ~tool_name:"masc_web_search" ~start_time (answer_of ~query response).data
  | Error failure -> failure_result ~tool_name:"masc_web_search" ~start_time failure
