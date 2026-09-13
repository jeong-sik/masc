open Alcotest
module R = Model_release_evidence

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
  (* The wire label spells the window in words; the number is named once and
     the two must move together. *)
  check int "one named recommendation window" 3 R.recency_window_months;
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
  let catalog = R.load_default () in
  (match catalog with
   | Ok _ -> ()
   | Error error -> fail error);
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
    ]
;;

(* Proves an unreadable default evidence file is projected as
   [status: unavailable] carrying the decode reason, on both the per-model and
   the catalog projection, while [status: unknown] stays reserved for an
   identity that is not in a readable file. On origin/main the decode error was
   swallowed into [Unknown] and the catalog dropped the reason. *)
let test_unreadable_default_file () =
  let open Yojson.Safe.Util in
  let as_of = date "2026-09-10" in
  let unreadable = R.of_string "{ \"schema\": \"masc.model_release_evidence.v1\", " in
  let reason =
    match unreadable with
    | Error reason -> reason
    | Ok _ -> fail "truncated evidence file decoded as a catalog"
  in
  let release = R.lookup unreadable ~publisher:"anthropic" ~model_id:"claude-sonnet-5" in
  check
    bool
    "unreadable file is not an unknown identity"
    true
    (release = R.Evidence_unavailable reason);
  let json = R.to_json ~as_of release in
  check string "per-model status" "unavailable" (json |> member "status" |> to_string);
  check string "per-model reason" reason (json |> member "reason" |> to_string);
  check string "no release date to judge" "unknown" (json |> member "recency" |> to_string);
  let catalog = R.catalog_to_json ~as_of unreadable in
  check string "catalog status" "unavailable" (catalog |> member "status" |> to_string);
  check string "catalog reason" reason (catalog |> member "reason" |> to_string);
  check int "catalog carries no models" 0 (catalog |> member "models" |> to_list |> List.length);
  let readable = R.of_string "{ \"schema\": \"masc.model_release_evidence.v1\", \"models\": [] }" in
  check
    bool
    "identity missing from a readable file stays unknown"
    true
    (R.lookup readable ~publisher:"anthropic" ~model_id:"claude-sonnet-5" = R.Unknown)
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

let test_picker_projection () =
  let json = R.catalog_to_json ~as_of:(date "2026-09-30") (R.load_default ()) in
  let open Yojson.Safe.Util in
  let rows = json |> member "models" |> to_list in
  let sonnet = List.find (fun row -> row |> member "publisher" |> to_string = "anthropic"
    && row |> member "model_id" |> to_string = "claude-sonnet-5") rows in
  let release = sonnet |> member "release" in
  check string "month-end inclusive release recommendation" "within_three_calendar_months"
    (release |> member "recency" |> to_string);
  check string "official date retained" "2026-06-30"
    (release |> member "released_on" |> to_string);
  check string "source retained" "https://www.anthropic.com/news/claude-sonnet-5"
    (release |> member "source_url" |> to_string);
  check bool "account availability is the envelope's fact, not the release's" true
    (release |> member "account_availability" = `Null)

let () =
  run
    "model release evidence"
    [ ( "recency and identity"
      , [ test_case "picker provenance projection" `Quick test_picker_projection
        ; test_case "calendar window boundaries" `Quick test_calendar_window
        ; test_case
            "embedded exact publisher and model provenance"
            `Quick
            test_embedded_exact_identity
        ; test_case
            "provider listing date is not release evidence"
            `Quick
            test_listing_date_cannot_be_release
        ; test_case
            "unreadable default file projects unavailable with its reason"
            `Quick
            test_unreadable_default_file
        ] )
    ]
;;
