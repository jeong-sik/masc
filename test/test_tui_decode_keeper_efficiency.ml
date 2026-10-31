(** Decoder tests for the [/api/v1/keeper-efficiency] month view. The TUI's
    state machine keeps what this decoder accepts; a defaulted or silently
    reshaped field would show up as a wrong efficiency row, so the decode is
    strict and these pin the refusal paths as well as the happy one. *)

open Alcotest

module D = Masc.Tui_decode_keeper_efficiency

let ok_month_json =
  `Assoc
    [ ("schema", `String "masc.keeper-efficiency/v1")
    ; ("month", `String "2026-10")
    ; ("generated_at", `Float 1793000000.0)
    ; ("days_covered", `Int 30)
    ; ( "fleet"
      , `Assoc
          [ ("turns_total", `Int 55653)
          ; ("calls_per_turn", `Float 11.98)
          ; ("tool_s_per_turn", `Float 46.4)
          ; ("output_tokens_per_turn", `Float 1211.0)
          ; ("input_tokens_per_turn", `Float 28000.0)
          ; ("cost_usd_per_turn", `Float 0.0)
          ] )
    ; ( "keepers"
      , `List
          [ `Assoc
              [ ("keeper", `String "simplifyer")
              ; ("turns", `Int 760)
              ; ("input_tokens", `Int 83823456)
              ; ("output_tokens", `Int 786614)
              ; ("cost_usd", `Float 0.0)
              ; ("calls", `Int 1463)
              ; ("failed", `Int 26)
              ; ("deferred", `Int 3)
              ; ("tool_ms", `Float 2972.5)
              ]
          ; `Assoc
              [ ("keeper", `String "kidsnote-job-manager")
              ; ("turns", `Int 744)
              ; ("input_tokens", `Int 4241040)
              ; ("output_tokens", `Int 75144)
              ; ("cost_usd", `Float 0.0)
              ; ("calls", `Int 3430)
              ; ("failed", `Int 130)
              ; ("deferred", `Int 1)
              ; ("tool_ms", `Float 6095.2)
              ]
          ] )
    ]
;;

let decode_ok json = D.of_json json |> Result.get_ok

let tests =
  [ ( "decodes a full month view and finds one keeper's row"
    , `Quick
    , fun () ->
      let view = decode_ok ok_month_json in
      check string "month" "2026-10" view.D.month;
      check int "days_covered" 30 view.D.days_covered;
      check int "keeper count" 2 (List.length view.D.keepers);
      check int "fleet turns" 55653 view.D.fleet.D.turns_total;
      let lazy_keeper = D.keeper_row view ~keeper:"kidsnote-job-manager" |> Option.get in
      check int "job-manager turns" 744 lazy_keeper.D.turns;
      check int "job-manager calls" 3430 lazy_keeper.D.calls;
      check bool "missing keeper is None" true (Option.is_none (D.keeper_row view ~keeper:"nope")) )
  ; ( "a wrong schema, a bad month, or a negative count refuses"
    , `Quick
    , fun () ->
      let fields = match ok_month_json with `Assoc f -> f | _ -> assert false in
      let with_field name value = `Assoc ((name, value) :: List.remove_assoc name fields) in
      (match D.of_json (with_field "schema" (`String "masc.other/v9")) with
       | Error (D.Unexpected_schema schema) -> check string "wrong schema" "masc.other/v9" schema
       | other -> Alcotest.failf "wrong schema accepted: %s" (match other with Ok _ -> "ok" | Error _ -> "wrong error"));
      (match D.of_json (with_field "month" (`String "2026-1")) with
       | Error (D.Invalid_field { field; _ }) -> check string "bad month field" "month" field
       | other -> Alcotest.failf "month shape accepted: %s" (match other with Ok _ -> "ok" | Error _ -> "wrong error"));
      (match D.of_json (with_field "days_covered" (`Int (-1))) with
       | Error (D.Invalid_field { field = "days_covered"; _ }) -> ()
       | other -> Alcotest.failf "negative count accepted: %s" (match other with Ok _ -> "ok" | Error _ -> "wrong error"));
      (match D.of_json (with_field "keepers" (`String "nope")) with
       | Error (D.Invalid_field { field = "keepers"; _ }) -> ()
       | other -> Alcotest.failf "non-list keepers accepted: %s" (match other with Ok _ -> "ok" | Error _ -> "wrong error"));
      check bool "non-object refuses" true (Result.is_error (D.of_json (`List []))) )
  ; ( "the response schema literal is the one the server emits"
    , `Quick
    , fun () ->
      (* Round-trip: the lib's own aggregator output decodes cleanly, so the
         TUI decoder and the server projection cannot drift apart. *)
      let root = Filename.concat (Filename.get_temp_dir_name ()) "ke_roundtrip" in
      (try Fs_compat.remove_tree root with _ -> ());
      Unix.mkdir root 0o755;
      (match Keeper_efficiency.read_month ~masc_root:root ~month:"2026-10" with
       | Ok view ->
         let json = Keeper_efficiency.month_view_to_json view in
         (match D.of_json json with
          | Ok decoded -> check string "month round-trips" view.Keeper_efficiency.month decoded.D.month
          | Error e -> Alcotest.failf "round-trip decode: %s" (D.decode_error_to_string e))
       | Error e -> Alcotest.failf "empty month read: %s" e) )
  ]

let () = run "Tui_decode_keeper_efficiency" [ ("decode", tests) ]
