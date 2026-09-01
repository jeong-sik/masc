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

(** URL validation *)
let valid_url url =
  let trimmed = String.trim url in
  if String.equal trimmed "" then false
  else
    let uri = Uri.of_string trimmed in
    match Uri.scheme uri |> Option.map String.lowercase_ascii with
    | Some "http" | Some "https" -> true
    | _ -> false

(* Boundary: web content decides what gets fetched next, so a request
   must not reach the loopback surface (MASC's own API included), the
   private network, or link-local metadata addresses. The check is
   literal — IP ranges via Ipaddr plus the RFC 6761 localhost names.
   It does not resolve DNS, so a public hostname that resolves to a
   private address is outside this boundary; that limitation is part
   of the contract, not hidden. Applied to the initial URL and to
   every redirect hop. *)
let rec blocked_ip_reason : Ipaddr.t -> string option = function
  | Ipaddr.V4 v4 ->
      if Ipaddr.V4.Prefix.(mem v4 loopback) then Some "loopback address"
      else if Ipaddr.V4.Prefix.(mem v4 link) then Some "link-local address"
      else if
        List.exists
          (fun block -> Ipaddr.V4.Prefix.mem v4 block)
          Ipaddr.V4.Prefix.private_blocks
      then Some "private-network address"
      else if Ipaddr.V4.compare v4 Ipaddr.V4.any = 0 then
        Some "unspecified address"
      else None
  | Ipaddr.V6 v6 -> (
      match Ipaddr.v4_of_v6 v6 with
      | Some v4 -> blocked_ip_reason (Ipaddr.V4 v4)
      | None ->
          if Ipaddr.V6.compare v6 Ipaddr.V6.localhost = 0 then
            Some "loopback address"
          else if Ipaddr.V6.Prefix.(mem v6 link) then Some "link-local address"
          else if Ipaddr.V6.Prefix.(mem v6 unique_local) then
            Some "private-network address"
          else if Ipaddr.V6.compare v6 Ipaddr.V6.unspecified = 0 then
            Some "unspecified address"
          else None)

let blocked_destination_reason url =
  match Uri.host (Uri.of_string (String.trim url)) with
  | None -> Some "URL has no host"
  | Some host ->
      let lowered = String.lowercase_ascii host in
      if
        String.equal lowered "localhost"
        || String.ends_with ~suffix:".localhost" lowered
      then Some "localhost is not fetchable"
      else (
        match Ipaddr.of_string lowered with
        | Error _ -> None (* hostname; resolution is out of scope here *)
        | Ok ip -> blocked_ip_reason ip)

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

(* Deterministic truncation, following the head/tail window Hermes uses
   for web extracts: keep the opening three quarters and the closing
   quarter of the budget, cut on line boundaries, and point at the
   offloaded full text instead of shipping it. Same input, same output. *)
let truncation_head_share_num = 3
let truncation_share_den = 4

(* [Env_config_core.base_path] is the guarded public accessor
   (RFC-0085 PR-9 hides the raw option form): unset becomes the
   canonical remedy message in the marker, and a #9903 test-isolation
   breach surfaces loudly as the offload reason instead of writing
   under the operator's HOME. *)
let web_artifact_index_schema = "masc.web_artifact.v1"

(* RFC-0383: one append-only fact line per offload. The index is a
   projection — the content-addressed file stays the truth, so an
   append failure must not turn a successful offload into a failure.
   The same sha256 offloaded again writes another row: an independent
   observation that the URL still had that content, with dedup already
   solved by content addressing at the file layer. *)
let web_artifact_index_append ~dir ~sha256 ~source_url ~title ~bytes
    ~fetched_at_unix =
  let row =
    `Assoc
      (List.concat
         [ [ ("schema", `String web_artifact_index_schema)
           ; ("sha256", `String sha256)
           ; ("source_url", `String source_url)
           ]
         ; (match title with
            | Some title -> [ ("title", `String title) ]
            | None -> [])
         ; [ ("bytes", `Int bytes)
           ; ( "fetched_at"
             , `String (Masc_domain.iso8601_of_unix_seconds fetched_at_unix) )
           ]
         ])
  in
  try Ok (Fs_compat.append_jsonl (Filename.concat dir "index.jsonl") row) with
  | Unix.Unix_error (err, _, _) -> Error (Unix.error_message err)
  | Sys_error message -> Error message

let offload_full_text ~source_url ~title ~fetched_at_unix text =
  match Env_config_core.base_path () with
  | exception Env_config_core.Config_error message -> Error message
  | base ->
      let dir =
        List.fold_left
          Filename.concat
          base
          [ Common.masc_dirname; "artifacts"; "web-fetch" ]
      in
      (* #28820: the full text lives in the content-addressed
         [Tool_blob_store], so the sha carried by the marker and the index
         is directly the input of [keeper_artifact_read] — a keeper-lane
         reader exists for it. This directory keeps only the discovery
         projection ([index.jsonl]). Filesystem failures become typed
         reasons in the marker; anything else propagates to the tool
         dispatch boundary rather than being flattened into a string
         here. *)
      (try
         let store = Tool_blob_store.create ~base_path:base in
         let artifact =
           Tool_blob_store.put_durable store ~bytes:text ~mime:"text/markdown"
         in
         (* The blob is durable at this point, so an index-side directory or
            append failure must surface as [index_unavailable], never as
            [full_text_unavailable] — the marker would otherwise deny a blob
            that exists. *)
         let index =
           try
             Fs_compat.mkdir_p dir;
             web_artifact_index_append ~dir
               ~sha256:artifact.Tool_output.sha256 ~source_url ~title
               ~bytes:(String.length text) ~fetched_at_unix
           with
           | Unix.Unix_error (err, _, _) -> Error (Unix.error_message err)
           | Sys_error message -> Error message
         in
         Ok (artifact.Tool_output.sha256, index)
       with
       | Unix.Unix_error (err, _, _) -> Error (Unix.error_message err)
       | Sys_error message -> Error message)

let is_utf8_continuation_byte byte = Char.code byte land 0xC0 = 0x80

(* When no newline is near the budget, the raw byte offset can land
   inside a multi-byte codepoint and ship silent mojibake. Snap the cut
   to a codepoint start: left for the head (excluded byte must start a
   codepoint), right for the tail (included byte must start one). Both
   walks are bounded and deterministic; invalid input degrades to an
   empty window, never a loop. *)
let snap_codepoint_left text index =
  let rec loop i =
    if i > 0 && is_utf8_continuation_byte text.[i] then loop (i - 1) else i
  in
  loop index

let snap_codepoint_right text index =
  let total = String.length text in
  let rec loop i =
    if i < total && is_utf8_continuation_byte text.[i] then loop (i + 1) else i
  in
  loop index

let outline_max_entries = 32

(* Byte-offset map of the extraction's markdown ATX headings, in order.
   Offsets index the offloaded artifact, so every entry doubles as a
   read address for keeper_artifact_read(sha256, offset, max_bytes) —
   the keeper picks a section instead of paging blindly. A one-bit
   fence toggle keeps `#` lines inside ``` blocks out of the map;
   imperfect fencing costs map precision, never correctness. Collection
   stops at [outline_max_entries] while the total keeps counting, so
   the marker can say how much of the document the map covers. *)
let document_outline text =
  let total = String.length text in
  let line_end offset =
    match String.index_from_opt text offset '\n' with
    | Some idx -> idx
    | None -> total
  in
  let rec walk offset in_fence collected collected_count heading_total =
    if offset >= total then List.rev collected, heading_total
    else
      let stop = line_end offset in
      let line = String.sub text offset (stop - offset) in
      let line_len = String.length line in
      let fence_line = line_len >= 3 && String.equal (String.sub line 0 3) "```" in
      let heading =
        (not in_fence) && (not fence_line)
        &&
        let rec hashes i =
          if i < line_len && Char.equal line.[i] '#' then hashes (i + 1) else i
        in
        let count = hashes 0 in
        count >= 1 && count <= 6 && count < line_len && Char.equal line.[count] ' '
      in
      let collected, collected_count =
        if heading && collected_count < outline_max_entries then
          (offset, line) :: collected, collected_count + 1
        else collected, collected_count
      in
      let heading_total = if heading then heading_total + 1 else heading_total in
      let in_fence = if fence_line then not in_fence else in_fence in
      walk (stop + 1) in_fence collected collected_count heading_total
  in
  walk 0 false [] 0 0

let outline_block text =
  match document_outline text with
  | [], _ -> None
  | entries, heading_total ->
      let header =
        Printf.sprintf
          "[OUTLINE headings=%d shown=%d — byte offsets into full_text for \
           keeper_artifact_read]"
          heading_total (Stdlib.List.length entries)
      in
      let rows =
        List.map (fun (offset, line) -> Printf.sprintf "%d %s" offset line) entries
      in
      Some (String.concat "\n" (header :: rows))

let truncate_text ~max_chars ~source_url ~title ~fetched_at_unix text =
  let total = String.length text in
  if total <= max_chars then text, false, None
  else
    let head_budget = max_chars * truncation_head_share_num / truncation_share_den in
    let tail_budget = max_chars - head_budget in
    let head_cut =
      if head_budget = 0 then 0
      else
        match String.rindex_from_opt text (head_budget - 1) '\n' with
        | Some idx when idx > 0 -> idx
        | Some _ | None -> snap_codepoint_left text head_budget
    in
    let tail_start =
      let minimum = total - tail_budget in
      match String.index_from_opt text minimum '\n' with
      | Some idx when idx + 1 < total -> idx + 1
      | Some _ | None -> snap_codepoint_right text minimum
    in
    let head = String.sub text 0 head_cut in
    let tail = String.sub text tail_start (total - tail_start) in
    let offloaded = offload_full_text ~source_url ~title ~fetched_at_unix text in
    let marker =
      match offloaded with
      | Ok (sha256, index) -> (
          let base =
            Printf.sprintf
              "[TRUNCATED total_chars=%d kept_head=%d kept_tail=%d full_text_sha256=%s]"
              total (String.length head) (String.length tail) sha256
          in
          (* RFC-0383: a failed index append never demotes a successful
             offload — the artifact is the truth and the index only a
             projection — but it does not pass silently either. The
             marker carries the reason, mirroring full_text_unavailable. *)
          let base =
            match index with
            | Ok () -> base
            | Error reason ->
                String.concat "\n"
                  [ base; Printf.sprintf "[index_unavailable=%s]" reason ]
          in
          (* The outline only ships when the offload succeeded: its
             offsets address the artifact file, and a map without an
             address surface would send the keeper nowhere. *)
          match outline_block text with
          | None -> base
          | Some outline -> String.concat "\n" [ base; outline ])
      | Error reason ->
          Printf.sprintf
            "[TRUNCATED total_chars=%d kept_head=%d kept_tail=%d full_text_unavailable=%s]"
            total (String.length head) (String.length tail) reason
    in
    ( String.concat "\n\n" [ head; marker; tail ]
    , true
    , match offloaded with Ok (sha256, _) -> Some sha256 | Error _ -> None )

(** Response cache. Authorization and admission belong to the Keeper Gate; this
    leaf does not maintain a second, process-local request limiter. *)
type cache_entry = {
  response : Yojson.Safe.t;
  expires_at : float;
}

module Cache_by_key = Set_util.StringMap

let cache_entries = Atomic.make Cache_by_key.empty
let cache_ttl_sec () = Env_config.Tools.web_search_cache_ttl_sec ()

let cache_lookup key now =
  let ttl = cache_ttl_sec () in
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
  let ttl = cache_ttl_sec () in
  if Stdlib.Float.compare ttl 0.0 > 0
  then
    Atomic_util.update cache_entries (fun current ->
      Cache_by_key.add key { response; expires_at = now +. ttl } current)

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
  | Transport_error _ -> Tool_result.Dependency_unavailable
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
  else (
    match blocked_destination_reason target with
    | Some reason -> Error ("redirect target rejected: " ^ reason)
    | None -> Ok ())

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

let http_fetch_cell = Atomic.make default_http_fetch

let current_http_fetch () = Atomic.get http_fetch_cell

let with_http_fetch_for_test http_fetch f =
  let previous = Atomic.exchange http_fetch_cell http_fetch in
  Stdlib.Fun.protect
    ~finally:(fun () -> Atomic.set http_fetch_cell previous)
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
let fetch_impl ~url ~timeout_sec ~extract_mode ~max_chars ~fetched_at_unix =
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
              let text, truncated, full_text_sha256 =
                truncate_text ~max_chars ~source_url:response.final_url ~title
                  ~fetched_at_unix rendered
              in
              Ok
                ( response
                , status
                , content_kind
                , extraction_source
                , title
                , description
                , text
                , truncated
                , full_text_sha256 ))
      | Some status -> Error (Http_status status)
      | None -> Error No_http_status)

(* RFC-0189 PR-1b.8 — typed result.
   Failure-class assignments live with construction:
   - [Workflow_rejection]: caller-input violation (invalid URL).
   - [Dependency_unavailable]:    rate-limit hit + transport-level failure
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
    match blocked_destination_reason url with
    | Some reason -> make_workflow_err ("url rejected: " ^ reason)
    | None ->
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
        (match fetch_impl ~url ~timeout_sec:timeout ~extract_mode ~max_chars
                 ~fetched_at_unix:start_time with
                    | Ok
                        ( response
                        , http_status
                        , content_kind
                        , extraction_source
                        , title
                        , description
                        , text
                        , truncated
                        , full_text_sha256 ) ->
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
                          (match full_text_sha256 with
                          | Some sha256 -> [ ("full_text_sha256", `String sha256) ]
                          | None -> [])
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
