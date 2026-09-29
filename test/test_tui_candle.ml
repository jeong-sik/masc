open Alcotest

let ready = Candle_observation.Ready
  {issued_milli="18446744073709551614000";burned_milli="1000";circulating_milli="18446744073709551613000"}

let () = run "tui_candle"
  ["observations", [
    test_case "exact decimal amounts beyond native and JS integers" `Quick (fun () ->
      check string "sub-Candle amount" "0.001" (Masc_tui_candle.amount_text "1");
      check string "zero is exact" "0.000" (Masc_tui_candle.amount_text "0");
      check (list string) "all three independently observed totals"
        ["Candle issued: 18446744073709551614.000";"Candle burned: 1.000";"Candle circulating: 18446744073709551613.000"]
        (Masc_tui_candle.summary_lines (Some (Ok ready))));
    test_case "Off hides; unavailable and disabled never show stale money" `Quick (fun () ->
      check (list string) "Off has no summary" [] (Masc_tui_candle.summary_lines (Some (Ok Candle_observation.Off)));
      check (option string) "Off hides even retained amount" None (Masc_tui_candle.balance_text (Some (Ok Candle_observation.Off)) (Some "9000"));
      check (option string) "source failure withdraws amount" (Some "unavailable: offline") (Masc_tui_candle.balance_text (Some (Error "offline")) (Some "9000"));
      check (option string) "disabled explains why" (Some "disabled: invalid policy") (Masc_tui_candle.balance_text (Some (Ok (Candle_observation.Disabled {reason="invalid policy"}))) (Some "9000"));
      check (option string) "ready zero is an observed zero" (Some "0.000 Candle") (Masc_tui_candle.balance_text (Some (Ok ready)) (Some "0")))]]
