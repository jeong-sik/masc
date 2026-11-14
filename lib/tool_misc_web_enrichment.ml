open Tool_args

let web_search_content_default_max_chars = 4_000
let web_search_content_max_chars_cap = 20_000

let clamp_int ~min ~max value = Stdlib.max min (Stdlib.min max value)

let assoc_replace key value fields =
  let rec loop acc = function
    | [] -> List.rev ((key, value) :: acc)
    | (k, _) :: rest when String.equal k key ->
        List.rev_append acc ((key, value) :: rest)
    | field :: rest -> loop (field :: acc) rest
  in
  loop [] fields

let json_field_string key = function
  | `Assoc fields ->
      (match List.assoc_opt key fields with
       | Some (`String value) -> Some value
       | _ -> None)
  | _ -> None

let json_field_int key = function
  | `Assoc fields ->
      (match List.assoc_opt key fields with
       | Some (`Int value) -> Some value
       | _ -> None)
  | _ -> None

let json_field_bool key = function
  | `Assoc fields ->
      (match List.assoc_opt key fields with
       | Some (`Bool value) -> Some value
       | _ -> None)
  | _ -> None

let append_assoc_fields fields additions =
  List.fold_left
    (fun acc (key, value) -> assoc_replace key value acc)
    fields
    additions

let assoc_field_string key fields =
  match List.assoc_opt key fields with
  | Some (`String value) ->
      let value = String.trim value in
      if String.equal value "" then None else Some value
  | _ -> None

let assoc_field_int key fields =
  match List.assoc_opt key fields with
  | Some (`Int value) -> Some value
  | _ -> None

let assoc_field_bool key fields =
  match List.assoc_opt key fields with
  | Some (`Bool value) -> Some value
  | _ -> None

let add_optional_line label value acc =
  match value with
  | Some value -> Printf.sprintf "%s: %s" label value :: acc
  | None -> acc

let add_optional_int_line label value acc =
  match value with
  | Some value -> Printf.sprintf "%s: %d" label value :: acc
  | None -> acc

let string_of_bool value = if value then "true" else "false"

let render_content_status fields =
  let status =
    match assoc_field_string "page_content_status" fields with
    | Some value -> value
    | None -> "unknown"
  in
  let details =
    []
    |> (fun acc ->
      match assoc_field_int "page_content_http_status" fields with
      | Some value -> Printf.sprintf "http=%d" value :: acc
      | None -> acc)
    |> (fun acc ->
      match assoc_field_int "page_content_chars" fields with
      | Some value -> Printf.sprintf "chars=%d" value :: acc
      | None -> acc)
    |> (fun acc ->
      match assoc_field_bool "page_content_truncated" fields with
      | Some value -> Printf.sprintf "truncated=%s" (string_of_bool value) :: acc
      | None -> acc)
    |> List.rev
  in
  let detail_text =
    match details with
    | [] -> ""
    | _ -> " (" ^ String.concat ", " details ^ ")"
  in
  let error_text =
    match assoc_field_string "page_content_error" fields with
    | Some value -> " - " ^ value
    | None -> ""
  in
  Printf.sprintf "Content status: %s%s%s" status detail_text error_text

let render_hit_content_text ((hit : Tool_misc_web_search.normalized_hit), fields) =
  let heading = Printf.sprintf "%d. %s" hit.rank hit.title in
  let content =
    match assoc_field_string "page_content" fields with
    | Some value -> value
    | None -> "(no page content available)"
  in
  let metadata =
    []
    |> add_optional_line "URL" (Some hit.url)
    |> add_optional_line "Snippet" (String_util.trim_nonempty hit.snippet)
    |> add_optional_line "Provider" (Some hit.source)
    |> add_optional_line "Content source" (assoc_field_string "page_content_source" fields)
    |> add_optional_line "Fetched URL" (assoc_field_string "page_content_final_url" fields)
    |> add_optional_line "Fetched title" (assoc_field_string "page_content_title" fields)
    |> List.rev
  in
  let lines =
    heading :: (metadata @ [ render_content_status fields; "Content:"; content ])
  in
  String.concat "\n" lines

let render_content_text ~content_max_chars ~content_timeout ~content_ok_count
  ~content_engine_text_count ~content_error_count result_fields hits =
  let metadata =
    []
    |> add_optional_line "Query" (assoc_field_string "query" result_fields)
    |> add_optional_line "Engine" (assoc_field_string "engine" result_fields)
    |> add_optional_line "Search URL" (assoc_field_string "search_url" result_fields)
    |> add_optional_int_line "Results" (assoc_field_int "result_count" result_fields)
    |> List.rev
  in
  let header =
    ("WebSearch readable results" :: metadata)
    @ [ Printf.sprintf
          "Content fetch: best_effort, ok=%d, engine_text=%d, unavailable=%d, \
           max_chars=%d, timeout=%ds"
          content_ok_count
          content_engine_text_count
          content_error_count
          content_max_chars
          content_timeout
      ]
  in
  let body =
    match hits with
    | [] -> "No results."
    | _ -> hits |> List.map render_hit_content_text |> String.concat "\n\n---\n\n"
  in
  String.concat "\n" header ^ "\n\n" ^ body

let failed_page_content_note ~url message =
  let message = String.trim message in
  let message = if String.equal message "" then "unknown error" else message in
  Printf.sprintf "_Failed to retrieve page content: %s_\n\nSource: %s\n" message url

(* What a result's [content_text] entry holds. The kinds are counted apart,
   so a reader never takes the engine's text for the fetched page. *)
type hit_content =
  | Page_fetched      (* the result's page, fetched with WebFetch *)
  | Engine_text_kept  (* the page fetch failed; the engine's text stands in *)
  | Unavailable       (* the page fetch failed and the engine gave no text *)

let fetched_page_source = "fetched page"

let fetch_page_content_for_search_hit ~content_max_chars ~content_timeout url =
  let fetch_args =
    `Assoc
      [ "url", `String url
      ; "extractMode", `String "markdown"
      ; "maxChars", `Int content_max_chars
      ; "timeout", `Int content_timeout
      ]
  in
  let start_time = Tool_timing.start () in
  let fetch_result =
    Tool_misc_web_fetch.handle
      ~tool_name:"masc_web_fetch"
      ~start_time
      fetch_args
  in
  if Tool_result.is_success fetch_result then (
    let data = Tool_result.data fetch_result in
    match json_field_string "text" data with
    | None -> Error "WebFetch success payload missing text field"
    | Some text ->
        let fields =
          [ "page_content_status", `String "ok"
          ; "page_content_source", `String fetched_page_source
          ; "page_content", `String text
          ]
        in
        let fields =
          match json_field_string "final_url" data with
          | Some value -> ("page_content_final_url", `String value) :: fields
          | None -> fields
        in
        let fields =
          match json_field_int "http_status" data with
          | Some value -> ("page_content_http_status", `Int value) :: fields
          | None -> fields
        in
        let fields =
          match json_field_int "content_chars" data with
          | Some value -> ("page_content_chars", `Int value) :: fields
          | None -> fields
        in
        let fields =
          match json_field_bool "truncated" data with
          | Some value -> ("page_content_truncated", `Bool value) :: fields
          | None -> fields
        in
        let fields =
          match json_field_string "title" data with
          | Some value -> ("page_content_title", `String value) :: fields
          | None -> fields
        in
        Ok (List.rev fields))
  else Error (Tool_result.message fetch_result)

let failed_page_content_fields ~url message =
  [ "page_content_status", `String "error"
  ; "page_content", `String (failed_page_content_note ~url message)
  ; "page_content_error", `String message
  ]

(* The engine's text for a page that could not be fetched, cut to the same
   [contentMaxChars] a fetched page gets. Its source line names the engine,
   and the status keeps the fetch failure. *)
let engine_text_fields ~content_max_chars ~source ~fetch_error text =
  let kept = String_util.utf8_safe ~max_bytes:content_max_chars ~suffix:"…" text in
  let content = String_util.to_string kept in
  [ "page_content_status", `String "engine_text"
  ; ( "page_content_source"
    , `String
        (Printf.sprintf "text the %s search engine returned with this result, \
                         not the fetched page" source) )
  ; "page_content", `String content
  ; "page_content_chars", `Int (String.length content)
  ; "page_content_truncated", `Bool (String_util.was_truncated kept)
  ; "page_content_error", `String ("page fetch failed: " ^ fetch_error)
  ]

let enrich_web_search_hit ~content_max_chars ~content_timeout
    (hit : Tool_misc_web_search.normalized_hit) =
  match
    fetch_page_content_for_search_hit ~content_max_chars ~content_timeout hit.url
  with
  | Ok fields -> fields, Page_fetched
  | Error message ->
      (match hit.engine_text with
       | Some text ->
           ( engine_text_fields ~content_max_chars ~source:hit.source
               ~fetch_error:message text
           , Engine_text_kept )
       | None -> failed_page_content_fields ~url:hit.url message, Unavailable)

let content_counts contents =
  List.fold_left
    (fun (fetched, engine_text, unavailable) (_, _, content) ->
       match content with
       | Page_fetched -> (fetched + 1, engine_text, unavailable)
       | Engine_text_kept -> (fetched, engine_text + 1, unavailable)
       | Unavailable -> (fetched, engine_text, unavailable + 1))
    (0, 0, 0) contents

let enrich_web_search_payload ~content_max_chars ~content_timeout hits data =
  match data with
  | `Assoc fields ->
      (match List.assoc_opt "result" fields with
       | Some (`Assoc result_fields) ->
           let contents =
             List.map
               (fun hit ->
                  let content_fields, content =
                    enrich_web_search_hit ~content_max_chars ~content_timeout hit
                  in
                  hit, content_fields, content)
               hits
           in
           let content_ok_count, content_engine_text_count, content_error_count =
             content_counts contents
           in
           (* Fetched bodies ride only in [content_text]. Mirroring
              them into [results.[].page_content] doubled every byte
              through [Tool_result.message]'s whole-payload
              serialization with no reader on the structured copy. *)
           let result_fields =
             append_assoc_fields result_fields
               [ "content_enriched", `Bool true
               ; "content_fetch_mode", `String "best_effort"
               ; "content_max_chars", `Int content_max_chars
               ; "content_timeout", `Int content_timeout
               ; "content_result_count", `Int content_ok_count
               ; "content_engine_text_count", `Int content_engine_text_count
               ; "content_error_count", `Int content_error_count
               ; ( "content_text",
                   `String
                     (render_content_text
                        ~content_max_chars
                        ~content_timeout
                        ~content_ok_count
                        ~content_engine_text_count
                        ~content_error_count
                        result_fields
                        (List.map (fun (hit, fields, _) -> (hit, fields)) contents)) )
               ]
           in
           `Assoc (assoc_replace "result" (`Assoc result_fields) fields)
       | _ -> data)
  | _ -> data

let handle ~tool_name ~start_time args =
  if not (get_bool args "includeContent" false) then
    Tool_misc_web_search.handle ~tool_name ~start_time args
  else
    let content_max_chars =
      get_int args "contentMaxChars" web_search_content_default_max_chars
      |> clamp_int ~min:100 ~max:web_search_content_max_chars_cap
    in
    let content_timeout =
      get_int args "contentTimeout" Tool_misc_web_fetch.default_timeout_sec
      |> clamp_int ~min:1 ~max:60
    in
    Tool_misc_web_search.handle_with_rows ~tool_name ~start_time args
      ~on_rows:(enrich_web_search_payload ~content_max_chars ~content_timeout)
