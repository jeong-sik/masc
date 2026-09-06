let check = Alcotest.check
let string = Alcotest.string
let int = Alcotest.int
let bool = Alcotest.bool

module T = Masc_tui_model_runtime_table

let sample =
  [ "[models.alpha]"
  ; "api-name = \"alpha-v2\""
  ; "# reasoning-effort = \"high\"   <- commented out, not a value"
  ; "reasoning-effort = \"low\""
  ; "temperature = 0.7"
  ; ""
  ; "[models.alpha.capabilities]"
  ; "max-tokens = 999"
  ; ""
  ; "[ollama_cloud.alpha]"
  ; "max-tokens = 16384"
  ; ""
  ; "[models.beta]"
  ; "streaming = true"
  ; ""
  ; "[ollama_cloud.beta]"
  ; "max-concurrent = 2"
  ; ""
  ; "[providers.ollama_cloud]"
  ; "base-url = \"https://ollama.com\""
  ; ""
  ; "[voice.tts]"
  ; "enabled = true"
  ]

let row_named rows name =
  match List.find_opt (fun (r : T.row) -> String.equal r.T.model name) rows with
  | Some r -> r
  | None -> Alcotest.failf "row %S is missing" name

let test_reads_both_tables () =
  let alpha = row_named (T.parse sample) "alpha" in
  check string "provider" "ollama_cloud" alpha.T.provider;
  check string "api name" "alpha-v2" (Option.get alpha.T.api_name);
  check
    string
    "effort comes from the models table"
    "low"
    (Option.get alpha.T.reasoning_effort);
  check string "temperature comes from the models table" "0.7"
    (Option.get alpha.T.temperature);
  check int "max-tokens comes from the binding" 16384 (Option.get alpha.T.max_tokens)

let test_absent_knobs_stay_absent () =
  let beta = row_named (T.parse sample) "beta" in
  check bool "no effort" true (Option.is_none beta.T.reasoning_effort);
  check bool "no temperature" true (Option.is_none beta.T.temperature);
  check bool "no max-tokens" true (Option.is_none beta.T.max_tokens)

(* [providers.X] and [voice.Y] have the same two-part shape as a binding.
   Before the models-table pairing they landed in the table as rows with two
   empty knob columns, which reads as "a model nobody configured". *)
let test_non_model_sections_are_not_rows () =
  let names = List.map (fun (r : T.row) -> r.T.model) (T.parse sample) in
  check bool "no provider row" false (List.mem "ollama_cloud" names);
  check bool "no voice row" false (List.mem "tts" names);
  check int "only the two models" 2 (List.length names)

(* [models.alpha.capabilities] carries its own max-tokens. Treating the
   sub-table as a continuation of [models.alpha] would read 999 for a
   binding whose real cap is 16384. *)
let test_sub_tables_do_not_leak () =
  let alpha = row_named (T.parse sample) "alpha" in
  check int "binding value wins" 16384 (Option.get alpha.T.max_tokens)

let test_commented_lines_are_not_values () =
  let lines =
    [ "[models.gamma]"; "# reasoning-effort = \"max\""; "[ollama_cloud.gamma]"; "max-tokens = 1" ]
  in
  let gamma = row_named (T.parse lines) "gamma" in
  check bool "comment ignored" true (Option.is_none gamma.T.reasoning_effort)

let test_render_columns_line_up () =
  let rendered = T.render ~width:80 (T.parse sample) in
  match rendered with
  | header :: rows ->
    let effort_col =
      (* Locate by the header word rather than a fixed number so the test
         tracks the layout instead of restating it. [String.index_opt] used
         to be matched here and the single arm ignored it. *)
      let rec find i =
        if i + 6 > String.length header then -1
        else if String.equal (String.sub header i 6) "effort" then i
        else find (i + 1)
      in
      find 0
    in
    check bool "effort header found" true (effort_col >= 0);
    List.iter
      (fun row ->
        check
          bool
          "row is at least as wide as the effort column"
          true
          (String.length row > effort_col))
      rows
  | [] -> Alcotest.fail "render produced nothing"

let test_empty_input () =
  check
    string
    "empty says so"
    "no model bindings in runtime.toml"
    (List.hd (T.render ~width:80 []))

let test_detail_names_owners_and_api_override () =
  let alpha = row_named (T.parse sample) "alpha" in
  check
    (Alcotest.list string)
    "selected binding detail"
    [ "Binding: provider=ollama_cloud  model=alpha"
    ; "API model: alpha-v2 (api-name override)"
    ; "[models.alpha]  reasoning-effort=low  temperature=0.7"
    ; "[ollama_cloud.alpha]  max-tokens=16384"
    ; "- means that key is absent; add or edit it in the section shown above."
    ]
    (T.detail_lines alpha)

let test_detail_explains_absent_values () =
  let beta = row_named (T.parse sample) "beta" in
  check
    (Alcotest.list string)
    "absent values and default API name"
    [ "Binding: provider=ollama_cloud  model=beta"
    ; "API model: beta (default; api-name key absent)"
    ; "[models.beta]  reasoning-effort=-  temperature=-"
    ; "[ollama_cloud.beta]  max-tokens=-"
    ; "- means that key is absent; add or edit it in the section shown above."
    ]
    (T.detail_lines beta)

let test_detail_quotes_dotted_model_section () =
  let row : T.row =
    { model = "glm-5.2"
    ; provider = "glm-coding"
    ; api_name = None
    ; reasoning_effort = None
    ; temperature = None
    ; max_tokens = None
    }
  in
  let detail = T.detail_lines row in
  check string "models section quotes the dotted key"
    "[models.\"glm-5.2\"]  reasoning-effort=-  temperature=-"
    (List.nth detail 2);
  check string "binding section quotes the dotted key"
    "[glm-coding.\"glm-5.2\"]  max-tokens=-"
    (List.nth detail 3)

let () =
  Alcotest.run
    "masc_tui_model_runtime_table"
    [ ( "parse"
      , [ Alcotest.test_case "reads both tables" `Quick test_reads_both_tables
        ; Alcotest.test_case "absent knobs stay absent" `Quick test_absent_knobs_stay_absent
        ; Alcotest.test_case
            "non-model sections are not rows"
            `Quick
            test_non_model_sections_are_not_rows
        ; Alcotest.test_case "sub-tables do not leak" `Quick test_sub_tables_do_not_leak
        ; Alcotest.test_case "commented lines are not values" `Quick test_commented_lines_are_not_values
        ] )
    ; ( "render"
      , [ Alcotest.test_case "columns line up" `Quick test_render_columns_line_up
        ; Alcotest.test_case "empty input" `Quick test_empty_input
        ; Alcotest.test_case
            "detail names owners and API override"
            `Quick
            test_detail_names_owners_and_api_override
        ; Alcotest.test_case
            "detail explains absent values"
            `Quick
            test_detail_explains_absent_values
        ; Alcotest.test_case
            "detail quotes dotted model section"
            `Quick
            test_detail_quotes_dotted_model_section
        ] )
    ]
