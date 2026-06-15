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

let render_hit_content_text hit =
  match hit with
  | `Assoc fields ->
      let title =
        match assoc_field_string "title" fields with
        | Some value -> value
        | None -> "Untitled result"
      in
      let heading =
        match assoc_field_int "rank" fields with
        | Some rank -> Printf.sprintf "%d. %s" rank title
        | None -> title
      in
      let content =
        match assoc_field_string "page_content" fields with
        | Some value -> value
        | None -> "(no page content available)"
      in
      let metadata =
        []
        |> add_optional_line "URL" (assoc_field_string "url" fields)
        |> add_optional_line "Snippet" (assoc_field_string "snippet" fields)
        |> add_optional_line "Provider" (assoc_field_string "source" fields)
        |> add_optional_line "Fetched URL" (assoc_field_string "page_content_final_url" fields)
        |> add_optional_line "Fetched title" (assoc_field_string "page_content_title" fields)
        |> List.rev
      in
      let lines =
        heading :: (metadata @ [ render_content_status fields; "Content:"; content ])
      in
      String.concat "\n" lines
  | _ -> "Unreadable search result payload."

let render_content_text ~content_max_chars ~content_timeout ~content_ok_count
  ~content_error_count result_fields hits =
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
          "Content fetch: best_effort, ok=%d, unavailable=%d, max_chars=%d, timeout=%ds"
          content_ok_count
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

let fetch_page_content_for_search_hit ~content_max_chars ~content_timeout url =
  let fetch_args =
    `Assoc
      [ "url", `String url
      ; "extractMode", `String "markdown"
      ; "maxChars", `Int content_max_chars
      ; "timeout", `Int content_timeout
      ]
  in
  let start_time = Time_compat.now () in
  let fetch_result =
    Tool_misc_web_fetch.handle
      ~tool_name:"masc_web_fetch"
      ~start_time
      fetch_args
  in
  if Tool_result.is_success fetch_result then (
    let data = Tool_result.data fetch_result in
    match json_field_string "text" data with
    | None ->
        let message = "WebFetch success payload missing text field" in
        ( [ "page_content_status", `String "error"
          ; "page_content", `String (failed_page_content_note ~url message)
          ; "page_content_error", `String message
          ]
        , false )
    | Some text ->
        let fields =
          [ "page_content_status", `String "ok"
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
        List.rev fields, true)
  else
    ( [ "page_content_status", `String "error"
      ; "page_content", `String (failed_page_content_note ~url (Tool_result.message fetch_result))
      ; "page_content_error", `String (Tool_result.message fetch_result)
      ]
    , false )

let enrich_web_search_hit ~content_max_chars ~content_timeout hit =
  match hit with
  | `Assoc fields ->
      (match List.assoc_opt "url" fields with
       | Some (`String url) when not (String.equal (String.trim url) "") ->
           let additions, ok =
             fetch_page_content_for_search_hit
               ~content_max_chars
               ~content_timeout
               url
           in
           `Assoc (append_assoc_fields fields additions), ok
       | _ ->
           ( `Assoc
               (append_assoc_fields fields
                  [ "page_content_status", `String "skipped"
                  ; "page_content",
                    `String "_Skipped page content fetch: result has no URL._\n"
                  ])
           , false ))
  | other -> other, false

let enrich_web_search_results ~content_max_chars ~content_timeout hits =
  let ok_count = ref 0 in
  let enriched =
    List.map
      (fun hit ->
         let hit, ok =
           enrich_web_search_hit ~content_max_chars ~content_timeout hit
         in
         if ok then incr ok_count;
         hit)
      hits
  in
  let result_count = List.length hits in
  enriched, !ok_count, result_count - !ok_count

let enrich_web_search_payload ~tool_name ~start_time ~content_max_chars
  ~content_timeout data =
  match data with
  | `Assoc fields ->
      (match List.assoc_opt "result" fields with
       | Some (`Assoc result_fields) ->
           (match List.assoc_opt "results" result_fields with
            | Some (`List hits) ->
                let enriched_hits, content_ok_count, content_error_count =
                  enrich_web_search_results
                    ~content_max_chars
                    ~content_timeout
                    hits
                in
                let result_fields =
                  append_assoc_fields result_fields
                    [ "results", `List enriched_hits
                    ; "content_enriched", `Bool true
                    ; "content_fetch_mode", `String "best_effort"
                    ; "content_max_chars", `Int content_max_chars
                    ; "content_timeout", `Int content_timeout
                    ; "content_result_count", `Int content_ok_count
                    ; "content_error_count", `Int content_error_count
                    ; ( "content_text",
                        `String
                          (render_content_text
                             ~content_max_chars
                             ~content_timeout
                             ~content_ok_count
                             ~content_error_count
                             result_fields
                             enriched_hits) )
                    ]
                in
                Tool_result.make_ok
                  ~tool_name
                  ~start_time
                  ~data:(`Assoc (assoc_replace "result" (`Assoc result_fields) fields))
                  ()
            | _ -> Tool_result.make_ok ~tool_name ~start_time ~data ())
       | _ -> Tool_result.make_ok ~tool_name ~start_time ~data ())
  | _ -> Tool_result.make_ok ~tool_name ~start_time ~data ()

let enrich_result_if_requested ~tool_name ~start_time args result =
  if not (Tool_result.is_success result) then result
  else if not (get_bool args "includeContent" false) then result
  else
    let content_max_chars =
      get_int args "contentMaxChars" web_search_content_default_max_chars
      |> clamp_int ~min:100 ~max:web_search_content_max_chars_cap
    in
    let content_timeout =
      get_int args "contentTimeout" Tool_misc_web_fetch.default_timeout_sec
      |> clamp_int ~min:1 ~max:60
    in
    enrich_web_search_payload
      ~tool_name
      ~start_time
      ~content_max_chars
      ~content_timeout
      (Tool_result.data result)
