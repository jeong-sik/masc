(** Catalog rows that accept the reasoning-effort "none" rung must declare
    how the disable is encoded on the wire.

    The install wizard composes [enable_thinking = false] targets against
    OpenRouter rows whose probe answered 200 with zero billed reasoning
    tokens for effort "none" (probe7, evidence/task-openrouter-support/).
    Admission refuses such a target when the row carries no
    [thinking_control_format]: the disable is unencodable, not merely
    unverified, and the slot is excluded pre-flight (live incident
    2026-09-12, issue #35250 -- the librarian lane's third slot served
    zero requests while every other tier walked). This suite pins the
    invariant for the OpenRouter family so a future row that accepts
    "none" without naming its control dialect fails here instead of in
    production. Other providers stay out of scope: their disable dialects
    are probed and declared per provider, and this suite asserts only the
    contract the wizard actually composes. *)

let openrouter_entries () =
  match Llm_provider.Model_catalog.load_default () with
  | Error detail -> Alcotest.failf "default model catalog failed to load: %s" detail
  | Ok catalog ->
    Llm_provider.Model_catalog.model_entries catalog
    |> List.filter (fun (entry : Llm_provider.Model_catalog.model_entry) ->
           entry.Llm_provider.Model_catalog.provider_name = Some "openrouter")

let test_none_accepting_rows_declare_a_control_format () =
  let offenders =
    openrouter_entries ()
    |> List.filter (fun entry ->
           let efforts =
             entry.Llm_provider.Model_catalog.accepted_reasoning_efforts
           in
           Option.exists (List.exists (String.equal "none")) efforts
           && entry.Llm_provider.Model_catalog.thinking_control_format = None)
    |> List.map (fun entry -> entry.Llm_provider.Model_catalog.id_prefix)
  in
  Alcotest.(check (list string))
    "every OpenRouter row accepting effort none declares thinking_control_format"
    [] offenders

let () =
  Alcotest.run "model_catalog_thinking_control"
    [ ( "thinking control"
      , [ Alcotest.test_case
            "none-accepting openrouter rows declare a control format"
            `Quick test_none_accepting_rows_declare_a_control_format
        ] )
    ]
