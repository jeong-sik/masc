(* The TUI draws Candle amounts from the roster's decay basis at draw time
   (RFC-0481 §3.7). The checks are on the computed amounts, read through the
   module's own text, for one wallet that halves in an hour. *)

module Candle = Masc_tui_candle
module Decode = Masc.Tui_decode

let since = "2026-09-29T00:00:00Z"

let since_s =
  match Candle_time.of_rfc3339 since with
  | Ok at -> Ptime.to_float_s (Candle_time.to_ptime at)
  | Error detail -> Alcotest.fail detail

let one_hour_s = 3600.0

let reading =
  let basis =
    Candle_decay_basis.of_json
      (`Assoc
        [ "issued_milli", `String "1000"; "burned_milli", `String "0"; "half_life", `Int 1
        ; "keepers", `List [ `Assoc [ "name", `String "alpha"; "since", `String since
                                    ; "amount_milli", `String "1000" ] ] ])
  in
  match basis with
  | Ok basis -> Some (Ok (Decode.Candle_ready basis))
  | Error detail -> Alcotest.fail detail

let test_a_balance_falls_with_the_half_life () =
  Alcotest.(check (option string)) "at its last event" (Some "1.000 Candle")
    (Candle.balance_text ~now:since_s reading ~keeper:"alpha");
  Alcotest.(check (option string)) "one half-life later" (Some "0.500 Candle")
    (Candle.balance_text ~now:(since_s +. one_hour_s) reading ~keeper:"alpha");
  Alcotest.(check (option string)) "a Keeper with no wallet" (Some "0.000 Candle")
    (Candle.balance_text ~now:(since_s +. one_hour_s) reading ~keeper:"beta")

let test_the_supply_burns_what_the_wallets_lost () =
  Alcotest.(check (list string)) "one half-life later"
    [ "Candle issued: 1.000"; "Candle burned: 0.500"; "Candle circulating: 0.500" ]
    (Candle.summary_lines ~now:(since_s +. one_hour_s) reading)

let test_a_clock_behind_the_ledger_draws_the_last_event () =
  Alcotest.(check (option string)) "a minute before the event" (Some "1.000 Candle")
    (Candle.balance_text ~now:(since_s -. 60.0) reading ~keeper:"alpha")

let test_the_items_tab_watches_the_basis_entry () =
  Alcotest.(check (option int)) "the wallet's amount at its last event" (Some 1000)
    (Option.map (fun (held : Candle_decay_basis.keeper) -> held.Candle_decay_basis.amount_milli)
       (Candle.keeper_basis reading ~keeper:"alpha"));
  Alcotest.(check bool) "no entry without a wallet" true
    (Option.is_none (Candle.keeper_basis reading ~keeper:"beta"))

let () =
  Alcotest.run "tui_candle"
    [ ( "candle"
      , [ Alcotest.test_case "a balance falls with the half-life" `Quick
            test_a_balance_falls_with_the_half_life
        ; Alcotest.test_case "the supply burns what the wallets lost" `Quick
            test_the_supply_burns_what_the_wallets_lost
        ; Alcotest.test_case "a clock behind the ledger draws the last event" `Quick
            test_a_clock_behind_the_ledger_draws_the_last_event
        ; Alcotest.test_case "the Items tab watches the basis entry" `Quick
            test_the_items_tab_watches_the_basis_entry
        ] )
    ]
