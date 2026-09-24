(* The Lanes surface names installed Add-ons in a row of its own. It used to
   print "No Add-ons installed." as a fixed sentence, so it said that whether
   or not any were installed and whether or not anything had read. Nothing on
   that surface fetches Add-ons -- launch_lanes_load takes standalone lanes
   only -- so the view behind the row is untouched until the operator opens
   them, and an untouched read is not an empty one. *)

open Alcotest
module UI = Masc_tui_lane_addons

let configuration : UI.configuration =
  { directory = "/addons"; complete = true; declarations = [] }

let declaration : UI.declaration =
  { source_path = "/addons/one.toml"
  ; installation_id = None
  ; desired = None
  ; applied = None
  ; instance_id = None
  ; issues = []
  }

let snapshot_of declarations : UI.snapshot =
  { instances = []
  ; output = { Masc.Lane_addon_types.rows = []; coverage = [] }
  ; complete = Some true
  ; configuration = Some { configuration with declarations }
  }

let view_of declarations = { UI.initial with snapshot = Some (snapshot_of declarations) }

let test_an_untouched_view_has_not_read () =
  check bool "nothing asked, nothing answered" true (UI.installed UI.initial = UI.Not_read)

(* A snapshot without a configuration is the Add-on stream answering about
   instances and output while the installation directory is still unread. *)
let test_a_snapshot_without_a_configuration_has_not_read_either () =
  let snapshot = { (snapshot_of []) with configuration = None } in
  check bool "no configuration is no reading" true
    (UI.installed { UI.initial with snapshot = Some snapshot } = UI.Not_read)

let test_a_read_that_found_none_says_so () =
  check bool "empty is its own answer" true (UI.installed (view_of []) = UI.Nothing_installed)

let test_a_read_that_found_some_counts_them () =
  check bool "two declarations" true
    (UI.installed (view_of [ declaration; declaration ]) = UI.Installed 2)

(* The status row's reading of the view. Measured on the live server at 150
   columns: pressing [o] drew

     Refreshing · previous reading remains visible
     No reading yet · r:refresh

   two rows apart, in the frame before the first read landed. The row matched
   on [loading] alone, so a read in flight claimed a previous reading whatever
   the view held. *)
let reading_of view = UI.status_text view

let loading view = { view with UI.loading = true }

let test_a_first_read_has_no_previous_reading () =
  check string "nothing held yet" "Reading · nothing held yet"
    (reading_of (loading UI.initial));
  check string "a refresh over a reading says so"
    "Refreshing · previous reading remains visible"
    (reading_of (loading (view_of [ declaration ])))

(* A retry after a failure holds nothing either, and the failure is the part
   an operator can act on. *)
let test_a_retry_after_a_failure_keeps_the_failure () =
  check string "the failure, and that it is being tried again"
    "Load failed: boom · reading again"
    (reading_of { (loading UI.initial) with UI.error = Some "boom" })

(* The readings this change does not touch. *)
let test_the_other_readings_are_unchanged () =
  check string "nothing asked for yet" "No reading yet · r:refresh"
    (reading_of UI.initial);
  check string "a reading in hand" "Recorded observations · r:refresh"
    (reading_of (view_of [ declaration ]));
  check string "a failed read with nothing behind it" "Load failed: boom"
    (reading_of { UI.initial with UI.error = Some "boom" });
  check string "a failure over a reading keeps both"
    "Error: boom · previous reading retained"
    (reading_of { (view_of [ declaration ]) with UI.error = Some "boom" })

let () =
  run "tui lane addon reading"
    [ ( "installed"
      , [ test_case "an untouched view has not read" `Quick
            test_an_untouched_view_has_not_read
        ; test_case "a snapshot without a configuration has not read either" `Quick
            test_a_snapshot_without_a_configuration_has_not_read_either
        ; test_case "a read that found none says so" `Quick
            test_a_read_that_found_none_says_so
        ; test_case "a read that found some counts them" `Quick
            test_a_read_that_found_some_counts_them
        ; test_case "a first read has no previous reading" `Quick
            test_a_first_read_has_no_previous_reading
        ; test_case "a retry after a failure keeps the failure" `Quick
            test_a_retry_after_a_failure_keeps_the_failure
        ; test_case "the other readings are unchanged" `Quick
            test_the_other_readings_are_unchanged
        ] )
    ]
