(** Four health readings, four marks.

    Exhaustiveness is the compiler's job; what it cannot check is that two
    readings did not quietly settle on the same character, or that a keeper
    that is not turning, or whose turns are failing, drew what a working
    keeper draws. *)

module Mark = Masc_tui_keeper_mark
module Reading = Masc.Tui_decode

let check_bool = Alcotest.(check bool)
let check_int = Alcotest.(check int)
let readings =
  [ "running", Reading.Health_running
  ; "idle", Reading.Health_idle
  ; "failing", Reading.Health_failing
  ; "offline", Reading.Health_offline
  ]

let test_the_column_legend_explains_every_letter_the_cell_draws () =
  let contains haystack needle =
    let n = String.length needle and h = String.length haystack in
    let rec go i = i + n <= h && (String.sub haystack i n = needle || go (i + 1)) in
    go 0
  in
  let modes =
    [ Reading.Activation_manual; Reading.Activation_on_demand; Reading.Activation_autonomous ]
  in
  let mode_letters = List.map Mark.activation_letter modes in
  check_int "each activation mode draws its own letter" (List.length modes)
    (List.length (List.sort_uniq String.compare mode_letters));
  let sandboxes = List.filter_map Mark.sandbox_of_profile [ "docker"; "microvm"; "remote_ssh" ] in
  check_int "the three declared profiles are sandboxes" 3 (List.length sandboxes);
  check_bool "a profile this build does not know is not one of them" true
    (Option.is_none (Mark.sandbox_of_profile "mock"));
  let sandbox_letters = List.map Mark.sandbox_letter sandboxes in
  check_int "each sandbox draws its own letter" 3
    (List.length (List.sort_uniq String.compare sandbox_letters));
  let keys = String.concat " " (List.map fst Mark.column_legend) in
  List.iter
    (fun letter -> check_bool ("the legend shows letter " ^ letter) true (contains keys letter))
    (mode_letters @ sandbox_letters);
  List.iter
    (fun header -> check_bool ("the legend names " ^ header) true (contains keys header))
    [ Mark.now_header; Mark.age_header; "LIFECYCLE"; Mark.failing_glyph; "Mode"; "S "; Mark.(badge_glyph Badge_schedule); "mem" ]

let () =
  Alcotest.run "tui_keeper_mark"
    [ ( "marks"
      , [ Alcotest.test_case "the column legend explains every letter" `Quick
            test_the_column_legend_explains_every_letter_the_cell_draws
        ] )
    ]
