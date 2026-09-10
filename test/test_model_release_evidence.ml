open Alcotest
module R = Masc.Model_release_evidence

let date value =
  match R.date_of_string value with
  | Ok date -> date
  | Error error -> fail error
;;

let evidence released =
  R.Official
    { released_on = date released
    ; kind = R.General_availability
    ; source_url = "https://official.example/releases/model"
    ; checked_on = date "2026-09-10"
    }
;;

let test_calendar_window () =
  List.iter
    (fun (now, expected) ->
       check
         string
         "calendar months clamp to valid day"
         expected
         (R.date_to_string (R.three_month_cutoff (date now))))
    [ "2026-09-10", "2026-06-10"
    ; "2026-05-31", "2026-02-28"
    ; "2024-05-31", "2024-02-29"
    ; "2026-01-31", "2025-10-31"
    ];
  let as_of = date "2026-09-10" in
  List.iter
    (fun (release, expected) ->
       check bool "release recency only" true (R.recency ~as_of release = expected))
    [ R.Unknown, R.Unknown_release
    ; evidence "2026-06-10", R.Within_three_months
    ; evidence "2026-06-09", R.Older_release
    ; evidence "2026-09-11", R.Future_release
    ];
  List.iter
    (fun input ->
       check bool "invalid date rejected" true (Result.is_error (R.date_of_string input)))
    [ "2026-02-29"; "2026-9-01"; "2026-09-10T00:00:00Z"; "0000-01-01" ]
;;

let test_embedded_exact_identity () =
  let catalog =
    match R.load_default () with
    | Ok value -> value
    | Error error -> fail error
  in
  let known = R.lookup catalog ~publisher:"anthropic" ~model_id:"claude-sonnet-5" in
  (match known with
   | R.Official value ->
     check
       string
       "official Sonnet release"
       "2026-06-30"
       (R.date_to_string value.released_on)
   | _ -> fail "missing verified release evidence");
  List.iter
    (fun (publisher, model_id) ->
       check
         bool
         "no guessed prefix or provider identity"
         true
         (R.lookup catalog ~publisher ~model_id = R.Unknown))
    [ "anthropic", "claude-sonnet-5-custom"
    ; "different-provider", "claude-sonnet-5"
    ; "zai", "glm-5.3"
    ];
  let json = R.to_json ~as_of:(date "2026-09-10") known in
  check
    string
    "release date does not prove account access"
    "not_checked"
    Yojson.Safe.Util.(json |> member "account_availability" |> to_string)
;;

let test_listing_date_cannot_be_release () =
  let listing =
    `Assoc
      [ "schema", `String "masc.model_release_evidence.v1"
      ; ( "models"
        , `List
            [ `Assoc
                [ "publisher", `String "fixture"
                ; "model_id", `String "recent-listing-old-model"
                ; ( "release"
                  , `Assoc [ "status", `String "unknown"; "created", `Int 1788998400 ] )
                ]
            ] )
      ]
  in
  check
    bool
    "created timestamp is rejected, not inferred"
    true
    (Result.is_error (R.of_json listing))
;;

let () =
  run
    "model release evidence"
    [ ( "recency and identity"
      , [ test_case "calendar window boundaries" `Quick test_calendar_window
        ; test_case
            "embedded exact publisher and model provenance"
            `Quick
            test_embedded_exact_identity
        ; test_case
            "provider listing date is not release evidence"
            `Quick
            test_listing_date_cannot_be_release
        ] )
    ]
;;
