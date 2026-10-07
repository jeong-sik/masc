(* Keeper-to-keeper Candle gifts: codec, balance projection, the ledger
   append and the keeper tool. Money moves, never mints; items change
   hands. Scenario prices are explicit test values, not product economic
   defaults. *)
open Alcotest
open Masc
module E = Candle_event
module U = Yojson.Safe.Util
module Item = Keeper_portrait_item

let ok = function
  | Ok value -> value
  | Error detail -> fail detail
;;

let at = ok (Candle_time.of_rfc3339 "2026-09-29T10:00:00Z")
let policy : E.t = { at; body = E.Half_life_set Candle_decay.Off }

let gifted_row from_keeper to_keeper amount_milli reason : E.t =
  { at; body = E.Gifted { from_keeper; to_keeper; amount_milli; reason } }
;;

let crown =
  match Item.of_id "crown" with
  | Some item -> item
  | None -> fail "catalog crown missing"
;;

let glasses =
  match Item.of_id "glasses" with
  | Some item -> item
  | None -> fail "catalog glasses missing"
;;

let test_kind () =
  check string "gifted" "gifted"
    (E.kind (E.Gifted { from_keeper = "a"; to_keeper = "b"; amount_milli = 10; reason = "thanks" }));
  check string "gifted_item" "gifted_item"
    (E.kind (E.Gifted_item { from_keeper = "a"; to_keeper = "b"; item = crown }))
;;

let test_line_round_trip () =
  let line = ok (E.to_line (gifted_row "alpha" "beta" 10 "welcome gift")) in
  (match E.of_line line with
   | Ok { at = _; body = E.Gifted g } ->
     check string "from" "alpha" g.from_keeper;
     check string "to" "beta" g.to_keeper;
     check int "amount" 10 g.amount_milli;
     check string "reason" "welcome gift" g.reason
   | Ok _ -> fail "gifted line read back as another kind"
   | Error detail -> fail detail);
  let line = ok (E.to_line { at; body = E.Gifted_item { from_keeper = "alpha"; to_keeper = "beta"; item = crown } }) in
  (match E.of_line line with
   | Ok { at = _; body = E.Gifted_item g } ->
     check string "from" "alpha" g.from_keeper;
     check string "to" "beta" g.to_keeper;
     check bool "item" true (g.item = crown)
   | Ok _ -> fail "gifted_item line read back as another kind"
   | Error detail -> fail detail)
;;

let test_decode_refusals () =
  let refused kind fields =
    let line =
      Printf.sprintf {|{"kind":%S,"at":"2026-09-29T10:00:00Z",%s}|} kind fields
    in
    match E.of_line line with
    | Ok _ -> fail ("accepted bad gift: " ^ fields)
    | Error _ -> ()
  in
  refused "gifted" {|"from_keeper":"a","to_keeper":"b","amount_milli":0,"reason":"thanks"|};
  refused "gifted" {|"from_keeper":"a","to_keeper":"b","amount_milli":-5,"reason":"thanks"|};
  refused "gifted" {|"from_keeper":"  ","to_keeper":"b","amount_milli":10,"reason":"thanks"|};
  refused "gifted" {|"from_keeper":"a","to_keeper":"b","amount_milli":10,"reason":"  "|};
  refused "gifted" {|"from_keeper":"a","to_keeper":"a","amount_milli":10,"reason":"thanks"|};
  refused "gifted" {|"from_keeper":"a","to_keeper":"b","amount_milli":10,"reason":"thanks","tip":1|};
  refused "gifted" {|"from_keeper":"a","to_keeper":"b","amount_milli":10|};
  refused "gifted_item" {|"from_keeper":"a","to_keeper":"b","item":"crown","extra":1|};
  refused "gifted_item" {|"from_keeper":"a","to_keeper":"a","item":"crown"|};
  refused "gifted_item" {|"from_keeper":"a","to_keeper":"b","item":"unknown_item"|};
  refused "gifted_item" {|"from_keeper":"a","to_keeper":"b"|};
;;

let state rows =
  match Candle_balance.of_events ~at (policy :: rows) with
  | Ok state -> state
  | Error error -> fail (Candle_balance.error_to_string error)
;;

let funded_state () =
  state [ { at; body = E.Granted { keeper = "alpha"; amount_milli = 100; reason = "seed" } } ]
;;

let test_balance_transfer () =
  let before = funded_state () in
  let after =
    ok
      (Candle_balance.gift before ~at ~from_keeper:"alpha" ~to_keeper:"beta" ~amount_milli:30
         ~reason:"thanks"
       |> Result.map_error Candle_balance.error_to_string)
  in
  check int "giver debited" 70 (Candle_balance.balance after ~keeper:"alpha");
  check int "receiver credited" 30 (Candle_balance.balance after ~keeper:"beta");
  let supply = Candle_balance.supply after in
  check string "issued untouched by a transfer" "100" supply.Candle_balance.issued_milli;
  check string "circulating untouched by a transfer" "100" supply.Candle_balance.circulating_milli
;;

let test_balance_duplicate_refused () =
  let before = funded_state () in
  let after =
    ok
      (Candle_balance.gift before ~at ~from_keeper:"alpha" ~to_keeper:"beta" ~amount_milli:30
         ~reason:"thanks"
       |> Result.map_error Candle_balance.error_to_string)
  in
  (match
     Candle_balance.gift after ~at ~from_keeper:"alpha" ~to_keeper:"beta" ~amount_milli:30
       ~reason:"thanks"
   with
   | Ok _ -> fail "second identical gift was accepted"
   | Error (Candle_balance.Duplicate_gift { from_keeper; to_keeper; reason }) ->
     check string "from" "alpha" from_keeper;
     check string "to" "beta" to_keeper;
     check string "reason" "thanks" reason
   | Error error -> fail ("wrong refusal: " ^ Candle_balance.error_to_string error));
  (* A different reason is a different occasion. *)
  (match
     Candle_balance.gift after ~at ~from_keeper:"alpha" ~to_keeper:"beta" ~amount_milli:30
       ~reason:"thanks again"
   with
   | Ok _ -> ()
   | Error error -> fail ("a second reason was refused: " ^ Candle_balance.error_to_string error))
;;

let test_balance_money_refusals () =
  let before = funded_state () in
  (match
     Candle_balance.gift before ~at ~from_keeper:"alpha" ~to_keeper:"beta" ~amount_milli:0
       ~reason:"thanks"
   with
   | Ok _ -> fail "zero gift was accepted"
   | Error (Candle_balance.Invalid_gift _) -> ()
   | Error error -> fail ("wrong refusal: " ^ Candle_balance.error_to_string error));
  (match
     Candle_balance.gift before ~at ~from_keeper:"alpha" ~to_keeper:"beta" ~amount_milli:101
       ~reason:"thanks"
   with
   | Ok _ -> fail "unfunded gift was accepted"
   | Error (Candle_balance.Insufficient_balance _) -> ()
   | Error error -> fail ("wrong refusal: " ^ Candle_balance.error_to_string error));
  (match
     Candle_balance.gift Candle_balance.empty ~at ~from_keeper:"alpha" ~to_keeper:"beta"
       ~amount_milli:10 ~reason:"thanks"
   with
   | Ok _ -> fail "gift before any policy was accepted"
   | Error Candle_balance.Missing_half_life -> ()
   | Error error -> fail ("wrong refusal: " ^ Candle_balance.error_to_string error))
;;

let test_balance_item_moves_ownership () =
  let owned_state =
    state
      [ { at; body = E.Granted { keeper = "alpha"; amount_milli = 2000; reason = "seed" } }
      ; { at; body = E.Purchased { keeper = "alpha"; item = crown; amount_milli = 700 } }
      ; { at; body = E.Purchased { keeper = "alpha"; item = glasses; amount_milli = 400 } }
      ]
  in
  let after =
    ok
      (Candle_balance.gift_item owned_state ~at ~from_keeper:"alpha" ~to_keeper:"beta" ~item:crown
       |> Result.map_error Candle_balance.error_to_string)
  in
  check bool "giver no longer owns" false
    (List.mem crown (Candle_balance.owned after ~keeper:"alpha"));
  check bool "receiver owns" true (List.mem crown (Candle_balance.owned after ~keeper:"beta"));
  check bool "ungifted item stays" true
    (List.mem glasses (Candle_balance.owned after ~keeper:"alpha"));
  (match
     Candle_balance.gift_item after ~at ~from_keeper:"alpha" ~to_keeper:"beta" ~item:crown
   with
   | Ok _ -> fail "a gift of an unowned item was accepted"
   | Error (Candle_balance.Unowned_gift _) -> ()
   | Error error -> fail ("wrong refusal: " ^ Candle_balance.error_to_string error));
  (match
     Candle_balance.gift_item after ~at ~from_keeper:"beta" ~to_keeper:"alpha" ~item:glasses
   with
   | Ok _ -> fail "a gift from a non-owner was accepted"
   | Error (Candle_balance.Unowned_gift _) -> ()
   | Error error -> fail ("wrong refusal: " ^ Candle_balance.error_to_string error))
;;

let test_balance_item_unequips_only_the_gift () =
  let equipped_state =
    state
      [ { at; body = E.Granted { keeper = "alpha"; amount_milli = 2000; reason = "seed" } }
      ; { at; body = E.Purchased { keeper = "alpha"; item = crown; amount_milli = 700 } }
      ; { at; body = E.Purchased { keeper = "alpha"; item = glasses; amount_milli = 400 } }
      ; { at
        ; body =
            E.Equipped
              { keeper = "alpha"; slot = Item.slot crown; choice = E.Item crown }
        }
      ; { at
        ; body =
            E.Equipped
              { keeper = "alpha"; slot = Item.slot glasses; choice = E.Item glasses }
        }
      ]
  in
  check bool "crown worn before the gift" true
    (Candle_balance.selection equipped_state ~keeper:"alpha" ~slot:(Item.slot crown)
     = E.Item crown);
  let after =
    ok
      (Candle_balance.gift_item equipped_state ~at ~from_keeper:"alpha" ~to_keeper:"beta"
         ~item:crown
       |> Result.map_error Candle_balance.error_to_string)
  in
  check bool "gifted item comes off" true
    (Candle_balance.selection after ~keeper:"alpha" ~slot:(Item.slot crown) = E.Default);
  check bool "anything else worn stays worn" true
    (Candle_balance.selection after ~keeper:"alpha" ~slot:(Item.slot glasses)
     = E.Item glasses);
  check bool "receiver look untouched" true
    (Candle_balance.selection after ~keeper:"beta" ~slot:(Item.slot crown) = E.Default)
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

let write_config config shop =
  let path =
    Config_dir_resolver.candle_toml_path_for_base_path
      ~base_path:config.Workspace.base_path
  in
  Fs_compat.mkdir_p (Filename.dirname path);
  Fs_compat.save_file path ("half_life = \"off\"\n" ^ payout_config ^ shop)
;;

let with_workspace f =
  let base_path = Filename.temp_dir "candle-gift-" "" in
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
       Candle_status.install_appraiser_check (fun () -> Ok ());
       let config = Workspace.default_config base_path in
       ignore (Workspace.init config ~agent_name:(Some "fixture-operator"));
       f config)
;;

let meta name =
  ok
    (Masc_test_deps.meta_of_json_fixture
       (`Assoc [ "name", `String name; "trace_id", `String ("trace-" ^ name) ]))
;;

let call config name tool args =
  Keeper_tool_in_process_runtime.handle_masc_misc_with_outcome
    ~config
    ~meta:(meta name)
    ~name:tool
    ~args
;;

let succeeded (result : Keeper_tool_execution.t) =
  match result.disposition, result.data with
  | Tool_result.Completed (), Some data -> data
  | _ -> failf "tool did not complete: %s" result.raw_output
;;

let rejected code (result : Keeper_tool_execution.t) =
  match result.disposition, result.data with
  | Tool_result.Failed _, Some data ->
    check string "typed refusal code" code U.(member "error_code" data |> to_string)
  | _ -> failf "expected refusal %s: %s" code result.raw_output
;;

let gift config keeper args = call config keeper "keeper_candle_gift" (`Assoc args)

let test_tool_money_gift_moves_money () =
  with_workspace (fun config ->
    write_config config "";
    let granted =
      Candle_grant.grant ~now:Time_compat.now ~base_path:config.Workspace.base_path
        ~keeper:(ok (Keeper_id.Keeper_name.of_string "keeper-a"))
        ~amount_milli:1000 ~reason:"seed"
    in
    (match granted with
     | Ok _ -> ()
     | Error error -> fail (Candle_grant.error_to_string error));
    let receipt =
      gift config "keeper-a"
        [ "to", `String "keeper-b"; "amount_milli", `Int 300; "reason", `String "thanks" ]
      |> succeeded
    in
    check string "kind" "money" U.(member "kind" receipt |> to_string);
    check string "amount" "300" U.(member "amount_milli" receipt |> to_string);
    check string "giver balance" "700" U.(member "from_balance_milli" receipt |> to_string);
    check string "receiver balance" "300" U.(member "to_balance_milli" receipt |> to_string);
    let balance =
      call config "keeper-b" "keeper_candle_balance" (`Assoc []) |> succeeded
    in
    check string "receiver wallet" "300" U.(member "balance_milli" balance |> to_string);
    (* The ledger row is a transfer the fold replays: granting nothing. *)
    let events =
      match Candle_ledger.read ~base_path:config.Workspace.base_path with
      | Ok view -> Candle_ledger.events view
      | Error error -> fail (Candle_ledger.read_error_to_string error)
    in
    let gifts =
      List.filter_map
        (fun (event : E.t) ->
          match event.body with E.Gifted _ -> Some () | _ -> None)
        events
    in
    check int "one gifted row" 1 (List.length gifts))
;;

let test_tool_item_gift_moves_ownership () =
  with_workspace (fun config ->
    write_config config "\n[shop.prices_milli]\ncrown = 700\n";
    let granted =
      Candle_grant.grant ~now:Time_compat.now ~base_path:config.Workspace.base_path
        ~keeper:(ok (Keeper_id.Keeper_name.of_string "keeper-a"))
        ~amount_milli:1000 ~reason:"seed"
    in
    (match granted with
     | Ok _ -> ()
     | Error error -> fail (Candle_grant.error_to_string error));
    let bought =
      call config "keeper-a" "keeper_candle_purchase" (`Assoc [ "item", `String "crown" ])
      |> succeeded
    in
    check string "crown bought" "crown" U.(member "item" bought |> to_string);
    let receipt =
      gift config "keeper-a" [ "to", `String "keeper-b"; "item", `String "crown" ]
      |> succeeded
    in
    check string "kind" "item" U.(member "kind" receipt |> to_string);
    check string "item" "crown" U.(member "item" receipt |> to_string);
    let giver =
      call config "keeper-a" "keeper_candle_balance" (`Assoc []) |> succeeded
    in
    check (list string) "giver no longer owns" []
      U.(member "owned_items" giver |> to_list |> List.map to_string);
    let receiver =
      call config "keeper-b" "keeper_candle_balance" (`Assoc []) |> succeeded
    in
    check (list string) "receiver owns" [ "crown" ]
      U.(member "owned_items" receiver |> to_list |> List.map to_string))
;;

let test_tool_gift_refusals () =
  with_workspace (fun config ->
    write_config config "\n[shop.prices_milli]\ncrown = 700\n";
    let granted =
      Candle_grant.grant ~now:Time_compat.now ~base_path:config.Workspace.base_path
        ~keeper:(ok (Keeper_id.Keeper_name.of_string "keeper-a"))
        ~amount_milli:100 ~reason:"seed"
    in
    (match granted with
     | Ok _ -> ()
     | Error error -> fail (Candle_grant.error_to_string error));
    (* Shape refusals name invalid_arguments. *)
    rejected "invalid_arguments"
      (gift config "keeper-a"
         [ "to", `String "keeper-b"
         ; "amount_milli", `Int 10
         ; "item", `String "crown"
         ; "reason", `String "thanks"
         ]);
    rejected "invalid_arguments"
      (gift config "keeper-a" [ "to", `String "keeper-b"; "reason", `String "thanks" ]);
    rejected "invalid_arguments"
      (gift config "keeper-a" [ "to", `String "keeper-b"; "amount_milli", `Int 10 ]);
    rejected "invalid_arguments"
      (gift config "keeper-a"
         [ "to", `String "keeper-b"; "item", `String "crown"; "reason", `String "thanks" ]);
    rejected "invalid_arguments"
      (gift config "keeper-a"
         [ "to", `String "keeper-b"; "item", `String "unknown_item" ]);
    (* A gift to self is refused at the boundary. *)
    rejected "invalid_gift"
      (gift config "keeper-a"
         [ "to", `String "keeper-a"; "amount_milli", `Int 10; "reason", `String "thanks" ]);
    (* Semantic refusals carry their own codes. *)
    rejected "insufficient_balance"
      (gift config "keeper-a"
         [ "to", `String "keeper-b"; "amount_milli", `Int 101; "reason", `String "thanks" ]);
    rejected "unowned_gift"
      (gift config "keeper-a" [ "to", `String "keeper-b"; "item", `String "crown" ]);
    ignore
      (gift config "keeper-a"
         [ "to", `String "keeper-b"; "amount_milli", `Int 10; "reason", `String "thanks" ]
       |> succeeded);
    rejected "duplicate_gift"
      (gift config "keeper-a"
         [ "to", `String "keeper-b"; "amount_milli", `Int 10; "reason", `String "thanks" ]))
;;

let () =
  Alcotest.run
    "candle_gift"
    [ ( "codec"
      , [ Alcotest.test_case "kind" `Quick test_kind
        ; Alcotest.test_case "line round trip" `Quick test_line_round_trip
        ; Alcotest.test_case "decode refusals" `Quick test_decode_refusals
        ] )
    ; ( "balance"
      , [ Alcotest.test_case "transfer moves money, not supply" `Quick test_balance_transfer
        ; Alcotest.test_case "duplicate refused, new reason pays" `Quick
            test_balance_duplicate_refused
        ; Alcotest.test_case "money refusals" `Quick test_balance_money_refusals
        ; Alcotest.test_case "item moves ownership" `Quick test_balance_item_moves_ownership
        ; Alcotest.test_case "item unequips only the gift" `Quick
            test_balance_item_unequips_only_the_gift
        ] )
    ; ( "tool"
      , [ Alcotest.test_case "money gift moves money" `Quick test_tool_money_gift_moves_money
        ; Alcotest.test_case "item gift moves ownership" `Quick
            test_tool_item_gift_moves_ownership
        ; Alcotest.test_case "gift refusals" `Quick test_tool_gift_refusals
        ] )
    ]
;;
