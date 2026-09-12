open Alcotest
module View = Masc_tui_runtime_config_view

(* The three rows above the runtime.toml listing. Both of the facts pinned here
   used to spend most of a row on characters that carried nothing: the source
   revision at its full sixty-four, and a clean validation spelling out that it
   had zero errors and zero warnings. *)

let issue severity =
  { View.key = "keeper.analyst.runtime"
  ; kind = View.Unknown_key
  ; severity
  ; detail = "no such key"
  }

let checked ?(valid = true) ?(issues = []) () =
  View.Checked
    { valid
    ; schema_version = 3
    ; current_schema_version = 3
    ; forward_schema = false
    ; issues
    }

let metadata ?(source_revision = "0123456789abcdef0123456789abcdef") ?validation () =
  { View.source_revision
  ; validation = (match validation with Some v -> v | None -> checked ())
  ; routing = View.Routing_active
  ; routing_requires_restart = false
  ; keeper = View.Applied
  ; keeper_requires_restart = false
  ; configured_count = 4
  ; pending_keys = []
  ; applied_keys = []
  ; preempted_keys = []
  }

let row n metadata = snd (List.nth (View.summary_lines metadata) n)
let revision metadata = row 0 metadata
let validation metadata = row 1 metadata

let test_the_revision_is_cut_to_a_comparable_length () =
  check string "twelve characters, not sixty-four"
    "Source revision: 0123456789ab"
    (revision (metadata ()));
  check string "a revision already short enough is left alone"
    "Source revision: source-7"
    (revision (metadata ~source_revision:"source-7" ()))

(* The prefix is the compact summary's economy, not the view's. [v] opens the
   detail screen to compare this read against the last one, and a prefix cannot
   be pasted into [git show]; test/test_tui_keyboard_input.py waits on the whole
   string there. *)
let test_the_detail_screen_keeps_the_whole_revision () =
  let read = metadata () in
  let detail n = snd (List.nth (View.detail_lines read) n) in
  check string "the revision whole, not its first twelve"
    "Source revision: 0123456789abcdef0123456789abcdef" (detail 0);
  check string "and the verdict under it is the summary's"
    (validation read) (detail 1)

let test_a_clean_read_does_not_count_to_zero () =
  check string "valid says it, and says no more" "Validation: valid"
    (validation (metadata ()))

let test_warnings_are_counted_because_valid_does_not_cover_them () =
  check string "one warning, singular"
    "Validation: valid \xc2\xb7 1 warning"
    (validation (metadata ~validation:(checked ~issues:[ issue View.Warning_issue ] ()) ()));
  check string "two warnings, plural"
    "Validation: valid \xc2\xb7 2 warnings"
    (validation
       (metadata
          ~validation:
            (checked ~issues:[ issue View.Warning_issue; issue View.Warning_issue ] ())
          ()))

let test_an_invalid_read_counts_its_errors () =
  check string "errors earn their place when the verdict is not valid"
    "Validation: invalid \xc2\xb7 1 error"
    (validation
       (metadata
          ~validation:(checked ~valid:false ~issues:[ issue View.Error_issue ] ())
          ()));
  check string "and warnings ride behind them"
    "Validation: invalid \xc2\xb7 1 error \xc2\xb7 1 warning"
    (validation
       (metadata
          ~validation:
            (checked ~valid:false
               ~issues:[ issue View.Error_issue; issue View.Warning_issue ]
               ())
          ()))

let test_a_file_that_would_not_parse_says_so () =
  check string "no counts to give" "Validation: invalid TOML"
    (validation (metadata ~validation:(View.Parse_error "line 4") ()))

let () =
  run "tui runtime config summary"
    [ ( "the rows above the listing"
      , [ test_case "the revision is cut to a comparable length" `Quick
            test_the_revision_is_cut_to_a_comparable_length
        ; test_case "the detail screen keeps the whole revision" `Quick
            test_the_detail_screen_keeps_the_whole_revision
        ; test_case "a clean read does not count to zero" `Quick
            test_a_clean_read_does_not_count_to_zero
        ; test_case "warnings are counted" `Quick
            test_warnings_are_counted_because_valid_does_not_cover_them
        ; test_case "an invalid read counts its errors" `Quick
            test_an_invalid_read_counts_its_errors
        ; test_case "a file that would not parse says so" `Quick
            test_a_file_that_would_not_parse_says_so
        ] )
    ]
