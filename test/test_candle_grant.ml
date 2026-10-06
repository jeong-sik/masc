(* Operator Candle gifts: codec, balance projection and the ledger append.
   Scenario prices are explicit test values, not product economic defaults. *)
open Alcotest
open Masc
module E = Candle_event

let ok = function
  | Ok value -> value
  | Error detail -> fail detail
;;

let ok_grant = function
  | Ok value -> value
  | Error error -> fail (Candle_grant.error_to_string error)
;;

let ok_ledger = function
  | Ok value -> value
  | Error error -> fail (Candle_ledger.read_error_to_string error)
;;

let at = ok (Candle_time.of_rfc3339 "2026-09-29T10:00:00Z")
let policy : E.t = { at; body = E.Half_life_set Candle_decay.Off }
let granted_row keeper amount_milli reason : E.t =
  { at; body = E.Granted { keeper; amount_milli; reason } }
;;

let test_kind () =
  check string "kind" "granted" (E.kind (E.Granted { keeper = "alpha"; amount_milli = 10; reason = "welcome gift" }))
;;

let test_line_round_trip () =
  let line = ok (E.to_line (granted_row "alpha" 10 "welcome gift")) in
  match E.of_line line with
  | Ok { at = _; body = E.Granted g } ->
    check string "keeper" "alpha" g.keeper;
    check int "amount" 10 g.amount_milli;
    check string "reason" "welcome gift" g.reason
  | Ok _ -> fail "granted line read back as another kind"
  | Error detail -> fail detail
;;

let line_of fields =
  Printf.sprintf {|{"kind":"granted","at":"2026-09-29T10:00:00Z",%s}|} fields
;;

let test_decode_refusals () =
  let refused fields =
    match E.of_line (line_of fields) with
    | Ok _ -> fail ("accepted bad grant: " ^ fields)
    | Error _ -> ()
  in
  refused {|"keeper":"alpha","amount_milli":0,"reason":"welcome gift"|};
  refused {|"keeper":"alpha","amount_milli":-5,"reason":"welcome gift"|};
  refused {|"keeper":"   ","amount_milli":10,"reason":"welcome gift"|};
  refused {|"keeper":"alpha","amount_milli":10,"reason":"  "|};
  refused {|"keeper":"alpha","amount_milli":10,"reason":"welcome gift","tip":1|};
  refused {|"keeper":"alpha","amount_milli":10|};
;;

let state rows =
  match Candle_balance.of_events ~at (policy :: rows) with
  | Ok state -> state
  | Error error -> fail (Candle_balance.error_to_string error)
;;

let test_balance_credit () =
  let before = state [ granted_row "alpha" 10 "welcome gift" ] in
  check int "granted balance" 10 (Candle_balance.balance before ~keeper:"alpha");
  check int "other keeper untouched" 0 (Candle_balance.balance before ~keeper:"beta");
  let supply = Candle_balance.supply before in
  check string "issued counts the grant" "10" supply.Candle_balance.issued_milli;
  check string "circulating counts the grant" "10" supply.Candle_balance.circulating_milli
;;

let test_balance_second_reason_accumulates () =
  let before =
    state [ granted_row "alpha" 10 "welcome gift"; granted_row "alpha" 5 "second gift" ]
  in
  check int "both gifts accumulate" 15 (Candle_balance.balance before ~keeper:"alpha")
;;

let test_balance_duplicate_refused () =
  let before = state [ granted_row "alpha" 10 "welcome gift" ] in
  match Candle_balance.grant before ~at ~keeper:"alpha" ~amount_milli:10 ~reason:"welcome gift" with
  | Ok _ -> fail "second identical grant was accepted"
  | Error (Candle_balance.Duplicate_grant { keeper; reason }) ->
    check string "keeper" "alpha" keeper;
    check string "reason" "welcome gift" reason
  | Error error -> fail ("wrong refusal: " ^ Candle_balance.error_to_string error)
;;

let test_balance_invalid_amount () =
  let before = state [] in
  match Candle_balance.grant before ~at ~keeper:"alpha" ~amount_milli:0 ~reason:"welcome gift" with
  | Ok _ -> fail "zero grant was accepted"
  | Error (Candle_balance.Invalid_grant _) -> ()
  | Error error -> fail ("wrong refusal: " ^ Candle_balance.error_to_string error)
;;

let test_balance_needs_policy () =
  match Candle_balance.grant Candle_balance.empty ~at ~keeper:"alpha" ~amount_milli:10 ~reason:"welcome gift" with
  | Ok _ -> fail "grant before any policy was accepted"
  | Error Candle_balance.Missing_half_life -> ()
  | Error error -> fail ("wrong refusal: " ^ Candle_balance.error_to_string error)
;;

let test_balance_overflow () =
  let before = state [ granted_row "alpha" max_int "fortune" ] in
  match Candle_balance.grant before ~at ~keeper:"alpha" ~amount_milli:1 ~reason:"one more" with
  | Ok _ -> fail "overflowing grant was accepted"
  | Error (Candle_balance.Balance_overflow keeper) ->
    check string "keeper" "alpha" keeper
  | Error error -> fail ("wrong refusal: " ^ Candle_balance.error_to_string error)
;;

let payout_config =
  {|[payout]
weight_max = 10
deduction_rate = 0
deduction_floor = 1000
share_rounding = "largest_remainder"
remainder_tie_break = "name_ascending"
deduction_rounding = "down"
[payout.grade_criteria]
trivial = "Minor adjustment"
small = "Bounded change"
medium = "Connected feature"
large = "Cross-feature work"
epic = "System outcome"
[payout.grades_milli]
trivial = 1000
small = 2000
medium = 3000
large = 4000
epic = 5000
|}
;;

let write_config config =
  let path =
    Config_dir_resolver.candle_toml_path_for_base_path
      ~base_path:config.Workspace.base_path
  in
  Fs_compat.mkdir_p (Filename.dirname path);
  Fs_compat.save_file path ("half_life = \"off\"\n" ^ payout_config)
;;

type config_setup = No_config | Garbage_config | Off_policy

let with_workspace ?(config_setup = Off_policy) f =
  let base_path = Filename.temp_dir "candle-grant-flow-" "" in
  Fun.protect
    ~finally:(fun () -> Masc_test_deps.cleanup_test_workspace base_path)
    (fun () ->
       Masc_test_deps.with_process_env Env_config_core.base_path_env_key (Some base_path)
       @@ fun () ->
       Masc_test_deps.with_process_env
         Env_config_core.config_dir_env_key
         None
       @@ fun () ->
       Eio_main.run
       @@ fun env ->
       Eio.Switch.run
       @@ fun sw ->
       Fs_compat.set_fs (Eio.Stdenv.fs env);
       Eio.Switch.on_release sw Fs_compat.clear_fs;
       Masc_test_deps.init_eio_clock ~sw env;
       Eio_context.with_test_env
         ~sw
         ~net:(Eio.Stdenv.net env)
         ~clock:(Eio.Stdenv.clock env)
         ~mono_clock:(Eio.Stdenv.mono_clock env)
       @@ fun () ->
       (* No appraiser check is installed: grants must work outside the
          server, where no lane registry installs one. *)
       let config = Workspace.default_config base_path in
       ignore (Workspace.init config ~agent_name:(Some "fixture-operator"));
       (match config_setup with
        | Off_policy -> write_config config
        | Garbage_config ->
          let path =
            Config_dir_resolver.candle_toml_path_for_base_path
              ~base_path:config.Workspace.base_path
          in
          Fs_compat.mkdir_p (Filename.dirname path);
          Fs_compat.save_file path "half_life = [oops\n"
        | No_config ->
          let path =
            Config_dir_resolver.candle_toml_path_for_base_path
              ~base_path:config.Workspace.base_path
          in
          (match Sys.remove path with
           | () -> ()
           | exception Sys_error _ -> ()));
       f config)
;;

let keeper name = ok (Keeper_id.Keeper_name.of_string name)
let fixed_now () = 1790800000.0

let item id =
  match Keeper_portrait_item.of_id id with
  | Some item -> item
  | None -> fail ("unknown test item: " ^ id)
;;

let test_grant_spends_in_shop () =
  with_workspace (fun config ->
    (* Purchases run through the appraiser gate in the server; the stub
       simulates a server present for this leg only. *)
    Candle_status.install_appraiser_check (fun () -> Ok ());
    let base_path = config.Workspace.base_path in
    let toml_path =
      Config_dir_resolver.candle_toml_path_for_base_path ~base_path
    in
    Fs_compat.save_file toml_path
      (Fs_compat.load_file toml_path ^ "\n[shop.prices_milli]\nglasses = 400\n");
    ignore
      (ok_grant
         (Candle_grant.grant
            ~now:fixed_now
            ~base_path
            ~keeper:(keeper "alpha")
            ~amount_milli:1000
            ~reason:"welcome gift"));
    let receipt =
      match
        Candle_shop.purchase
          ~now:fixed_now
          ~base_path
          ~keeper:(keeper "alpha")
          ~item:(item "glasses")
      with
      | Ok receipt -> receipt
      | Error error -> fail (Candle_shop.error_to_string error)
    in
    check int "grant funds the purchase" 600 receipt.Candle_shop.account.Candle_shop.balance_milli;
    check bool "purchase owns the item"
      true
      (List.mem
         (item "glasses")
         receipt.Candle_shop.account.Candle_shop.owned_items))

let test_grant_appends_row () =
  with_workspace (fun config ->
    let base_path = config.Workspace.base_path in
    let receipt =
      ok_grant
        (Candle_grant.grant
           ~now:fixed_now
           ~base_path
           ~keeper:(keeper "alpha")
           ~amount_milli:10
           ~reason:"welcome gift")
    in
    check int "receipt balance" 10 receipt.Candle_grant.balance_milli;
    check string "receipt reason" "welcome gift" receipt.Candle_grant.reason;
    let events = Candle_ledger.events (ok_ledger (Candle_ledger.read ~base_path)) in
    match List.rev events with
    | { body = E.Granted g; _ } :: _ ->
      check string "row keeper" "alpha" g.keeper;
      check int "row amount" 10 g.amount_milli;
      check string "row reason" "welcome gift" g.reason
    | _ -> fail "ledger tail is not the granted row")
;;

let test_grant_duplicate_refused () =
  with_workspace (fun config ->
    let base_path = config.Workspace.base_path in
    let grant () =
      Candle_grant.grant
        ~now:fixed_now
        ~base_path
        ~keeper:(keeper "alpha")
        ~amount_milli:10
        ~reason:"welcome gift"
    in
    ignore (ok_grant (grant ()));
    (match grant () with
     | Ok _ -> fail "second identical grant was appended"
     | Error (Candle_grant.Grant_refused (Candle_balance.Duplicate_grant _)) -> ()
     | Error error -> fail ("wrong refusal: " ^ Candle_grant.error_to_string error));
    let receipt =
      ok_grant
        (Candle_grant.grant
           ~now:fixed_now
           ~base_path
           ~keeper:(keeper "alpha")
           ~amount_milli:5
           ~reason:"second gift")
    in
    check int "balance after second reason" 15 receipt.Candle_grant.balance_milli;
    let events = Candle_ledger.events (ok_ledger (Candle_ledger.read ~base_path)) in
    let granted =
      List.filter
        (fun (event : E.t) -> match event.body with E.Granted _ -> true | _ -> false)
        events
    in
    check int "refused grant left no row" 2 (List.length granted))
;;

let test_grant_invalid_arguments () =
  with_workspace (fun config ->
    let base_path = config.Workspace.base_path in
    (match
       Candle_grant.grant
         ~now:fixed_now
         ~base_path
         ~keeper:(keeper "alpha")
         ~amount_milli:0
         ~reason:"welcome gift"
     with
     | Ok _ -> fail "zero grant was appended"
     | Error (Candle_grant.Invalid_grant _) -> ()
     | Error error -> fail ("wrong refusal: " ^ Candle_grant.error_to_string error));
    (match
       Candle_grant.grant
         ~now:fixed_now
         ~base_path
         ~keeper:(keeper "alpha")
         ~amount_milli:10
         ~reason:"   "
     with
     | Ok _ -> fail "blank-reason grant was appended"
     | Error (Candle_grant.Invalid_grant _) -> ()
     | Error error -> fail ("wrong refusal: " ^ Candle_grant.error_to_string error));
    let events = Candle_ledger.events (ok_ledger (Candle_ledger.read ~base_path)) in
    check bool "no rows from refused grants" true (events = []))
;;

let test_grant_trims_reason () =
  with_workspace (fun config ->
    let base_path = config.Workspace.base_path in
    ignore
      (ok_grant
         (Candle_grant.grant
            ~now:fixed_now
            ~base_path
            ~keeper:(keeper "alpha")
            ~amount_milli:10
            ~reason:"  welcome gift  "));
    let events = Candle_ledger.events (ok_ledger (Candle_ledger.read ~base_path)) in
    (match List.rev events with
     | { body = E.Granted g; _ } :: _ ->
       check string "stored reason is trimmed" "welcome gift" g.reason
     | _ -> fail "ledger tail is not the granted row");
    match
      Candle_grant.grant
        ~now:fixed_now
        ~base_path
        ~keeper:(keeper "alpha")
        ~amount_milli:10
        ~reason:"welcome gift"
    with
    | Ok _ -> fail "untrimmed retype paid twice"
    | Error (Candle_grant.Grant_refused (Candle_balance.Duplicate_grant _)) -> ()
    | Error error -> fail ("wrong refusal: " ^ Candle_grant.error_to_string error))
;;

let test_grant_first_row_is_policy () =
  with_workspace (fun config ->
    let base_path = config.Workspace.base_path in
    ignore
      (ok_grant
         (Candle_grant.grant
            ~now:fixed_now
            ~base_path
            ~keeper:(keeper "alpha")
            ~amount_milli:10
            ~reason:"welcome gift"));
    let events = Candle_ledger.events (ok_ledger (Candle_ledger.read ~base_path)) in
    match events with
    | { body = E.Half_life_set Candle_decay.Off; _ }
      :: { body = E.Granted _; _ } :: [] -> ()
    | _ -> fail "first grant must publish the policy boundary first")
;;

let test_grant_off_and_disabled () =
  with_workspace ~config_setup:No_config (fun config ->
    match
      Candle_grant.grant
        ~now:fixed_now
        ~base_path:config.Workspace.base_path
        ~keeper:(keeper "alpha")
        ~amount_milli:10
        ~reason:"welcome gift"
    with
    | Ok _ -> fail "grant without config was appended"
    | Error Candle_grant.Off -> ()
    | Error error -> fail ("wrong refusal: " ^ Candle_grant.error_to_string error));
  with_workspace ~config_setup:Garbage_config (fun config ->
    match
      Candle_grant.grant
        ~now:fixed_now
        ~base_path:config.Workspace.base_path
        ~keeper:(keeper "alpha")
        ~amount_milli:10
        ~reason:"welcome gift"
    with
    | Ok _ -> fail "grant with unreadable config was appended"
    | Error (Candle_grant.Disabled _) -> ()
    | Error error -> fail ("wrong refusal: " ^ Candle_grant.error_to_string error))
;;

let test_grant_invalid_history () =
  with_workspace (fun config ->
    let base_path = config.Workspace.base_path in
    let overspend : E.t =
      { at
      ; body =
          E.Purchased { keeper = "alpha"; item = item "glasses"; amount_milli = 99999 }
      }
    in
    (match Candle_ledger.update ~base_path (fun _ -> Ok ([ policy; overspend ], ())) with
     | Ok () -> ()
     | Error error ->
       fail
         (Candle_ledger.update_error_to_string
            (fun () -> "fixture")
            error));
    match
      Candle_grant.grant
        ~now:fixed_now
        ~base_path
        ~keeper:(keeper "alpha")
        ~amount_milli:10
        ~reason:"welcome gift"
    with
    | Ok _ -> fail "grant on a broken ledger was appended"
    | Error (Candle_grant.Account_invalid _) -> ()
    | Error error -> fail ("wrong refusal: " ^ Candle_grant.error_to_string error))
;;

let test_grant_overflow_op () =
  with_workspace (fun config ->
    let base_path = config.Workspace.base_path in
    ignore
      (ok_grant
         (Candle_grant.grant
            ~now:fixed_now
            ~base_path
            ~keeper:(keeper "alpha")
            ~amount_milli:max_int
            ~reason:"fortune"));
    match
      Candle_grant.grant
        ~now:fixed_now
        ~base_path
        ~keeper:(keeper "alpha")
        ~amount_milli:1
        ~reason:"one more"
    with
    | Ok _ -> fail "overflowing grant was appended"
    | Error (Candle_grant.Grant_refused (Candle_balance.Balance_overflow _)) -> ()
    | Error error -> fail ("wrong refusal: " ^ Candle_grant.error_to_string error))
;;

let test_grant_invalid_time () =
  with_workspace (fun config ->
    match
      Candle_grant.grant
        ~now:(fun () -> Float.nan)
        ~base_path:config.Workspace.base_path
        ~keeper:(keeper "alpha")
        ~amount_milli:10
        ~reason:"welcome gift"
    with
    | Ok _ -> fail "grant with a broken clock was appended"
    | Error (Candle_grant.Invalid_time _) -> ()
    | Error error -> fail ("wrong refusal: " ^ Candle_grant.error_to_string error))
;;

let test_grant_race_refuses_loser () =
  with_workspace (fun config ->
    let base_path = config.Workspace.base_path in
    let attempt () =
      Candle_grant.grant
        ~now:fixed_now
        ~base_path
        ~keeper:(keeper "alpha")
        ~amount_milli:10
        ~reason:"welcome gift"
    in
    let first, second =
      Eio.Switch.run (fun sw ->
        let p1, r1 = Eio.Promise.create () in
        let p2, r2 = Eio.Promise.create () in
        Eio.Fiber.fork ~sw (fun () -> Eio.Promise.resolve r1 (attempt ()));
        Eio.Fiber.fork ~sw (fun () -> Eio.Promise.resolve r2 (attempt ()));
        Eio.Promise.await p1, Eio.Promise.await p2)
    in
    let wins =
      List.filter_map (function Ok _ -> Some () | Error _ -> None) [ first; second ]
    in
    let dup_refusals =
      List.filter_map
        (function
          | Error (Candle_grant.Grant_refused (Candle_balance.Duplicate_grant _)) ->
            Some ()
          | _ -> None)
        [ first; second ]
    in
    check int "exactly one racer wins" 1 (List.length wins);
    check int "the loser is refused as duplicate" 1 (List.length dup_refusals);
    let events = Candle_ledger.events (ok_ledger (Candle_ledger.read ~base_path)) in
    let granted =
      List.filter
        (fun (event : E.t) -> match event.body with E.Granted _ -> true | _ -> false)
        events
    in
    check int "the race appends exactly one row" 1 (List.length granted))
;;

let test_grant_decays () =
  let t0 = at
  and t1 = ok (Candle_time.of_rfc3339 "2026-09-29T11:00:00Z") in
  let rows : E.t list =
    [ { at = t0; body = E.Half_life_set (Candle_decay.Hours 1) }
    ; { at = t0; body = E.Granted { keeper = "keeper"; amount_milli = 1000; reason = "welcome gift" } }
    ]
  in
  let projected =
    match Candle_balance.of_events ~at:t1 rows with
    | Ok state -> state
    | Error error -> fail (Candle_balance.error_to_string error)
  in
  check int "granted funds halve after one half-life" 500
    (Candle_balance.balance projected ~keeper:"keeper");
  let supply = Candle_balance.supply projected in
  check string "issuance stays a historical fact" "1000" supply.Candle_balance.issued_milli;
  check string "derived decay is burned" "500" supply.Candle_balance.burned_milli;
  check string "circulation equals the remaining wallet" "500" supply.Candle_balance.circulating_milli
;;

let test_max_int_round_trip () =
  let line = ok (E.to_line (granted_row "alpha" max_int "fortune")) in
  match E.of_line line with
  | Ok { body = E.Granted g; _ } -> check int "amount" max_int g.amount_milli
  | Ok _ -> fail "granted line read back as another kind"
  | Error detail -> fail detail
;;

let () =
  run
    "candle_grant"
    [ ( "codec",
        [ test_case "kind" `Quick test_kind
        ; test_case "line round trip" `Quick test_line_round_trip
        ; test_case "decode refusals" `Quick test_decode_refusals
        ; test_case "max_int round trip" `Quick test_max_int_round_trip
        ] )
    ; ( "balance",
        [ test_case "credit" `Quick test_balance_credit
        ; test_case "second reason accumulates" `Quick test_balance_second_reason_accumulates
        ; test_case "duplicate refused" `Quick test_balance_duplicate_refused
        ; test_case "invalid amount" `Quick test_balance_invalid_amount
        ; test_case "needs policy" `Quick test_balance_needs_policy
        ; test_case "overflow" `Quick test_balance_overflow
        ; test_case "grant decays" `Quick test_grant_decays
        ] )
    ; ( "ledger",
        [ test_case "appends row" `Quick test_grant_appends_row
        ; test_case "duplicate refused" `Quick test_grant_duplicate_refused
        ; test_case "invalid arguments" `Quick test_grant_invalid_arguments
        ; test_case "grant spends in shop" `Quick test_grant_spends_in_shop
        ; test_case "trims reason" `Quick test_grant_trims_reason
        ; test_case "first row is policy" `Quick test_grant_first_row_is_policy
        ; test_case "off and disabled" `Quick test_grant_off_and_disabled
        ; test_case "invalid history" `Quick test_grant_invalid_history
        ; test_case "overflow op" `Quick test_grant_overflow_op
        ; test_case "invalid time" `Quick test_grant_invalid_time
        ; test_case "race refuses loser" `Quick test_grant_race_refuses_loser
        ] )
    ]
