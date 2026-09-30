(* Real Keeper/MCP tools read and mutate the authoritative ledger. Values in
   this file are explicit scenario prices, not product economic defaults. *)
open Alcotest
open Masc
module E = Candle_event
module Item = Keeper_portrait_item
module U = Yojson.Safe.Util

let () = Mirage_crypto_rng_unix.use_default ()

let ok = function
  | Ok value -> value
  | Error detail -> fail detail
;;

let at = ok (Candle_time.of_rfc3339 "2026-09-29T10:00:00Z")
let json = testable Yojson.Safe.pp Yojson.Safe.equal

let payout_config =
  {|[payout]
weight_max = 10
deduction_rate = 0
deduction_floor = 1000
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
  Fs_compat.save_file path (payout_config ^ shop)
;;

let with_workspace f =
  let base_path = Filename.temp_dir "candle-purchase-flow-" "" in
  Fun.protect
    ~finally:(fun () -> Masc_test_deps.cleanup_test_workspace base_path)
    (fun () ->
       Masc_test_deps.with_process_env Env_config_core.base_path_env_key (Some base_path)
       @@ fun () ->
       (* Fresh test executables strip inherited config-directory overrides.
          Both processes must read the policy written under the explicit
          workspace base, not depend on the parent's post-startup override. *)
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
       write_config
         config
         "\n[shop.prices_milli]\nglasses = 400\nmedal = 700\ncrown = 700\n";
       f env sw config)
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

let balance config keeper =
  call config keeper "keeper_candle_balance" (`Assoc []) |> succeeded
;;

let buy config keeper item =
  call config keeper "keeper_candle_purchase" (`Assoc [ "item", `String item ])
;;

let ledger_path config = Candle_ledger.path ~base_path:config.Workspace.base_path
let bytes config = In_channel.with_open_bin (ledger_path config) In_channel.input_all

let events config =
  match Candle_ledger.read ~base_path:config.Workspace.base_path with
  | Ok view -> Candle_ledger.events view
  | Error error -> fail (Candle_ledger.read_error_to_string error)
;;

let append config rows =
  match
    Candle_ledger.update ~base_path:config.Workspace.base_path (fun _ -> Ok (rows, ()))
  with
  | Ok () -> ()
  | Error error -> fail (Candle_ledger.update_error_to_string Fun.id error)
;;

let credit config ~goal ~keeper amount =
  let payment =
    ok
      (Candle_payment.make
         ~identity:
           { goal_id = goal
           ; request_id = "confirmed-request"
           ; verification_run_id = "confirmed-verifier"
           }
         ~grade:Candle_grade.Trivial
         ~total_milli:amount
         ~grade_trace:{ run_id = "grade"; slot_id = "grade-slot" }
         ~relations:
           [ { task_id = "task"
             ; relation = Candle_appraisal.Related
             ; trace = { run_id = "relation"; slot_id = "relation-slot" }
             }
           ]
         ~weights_trace:{ run_id = "weights"; slot_id = "weights-slot" }
         ~weight_max:1
         ~deduction_rate:0
         ~deduction_floor:1000
         ~overdue_hours:0
         ~weights:[ keeper, 1 ])
  in
  append config [ { E.at; body = E.Paid payment } ]
;;

let purchases config =
  events config
  |> List.filter_map (fun (event : E.t) ->
    match event.body with
    | E.Purchased p -> Some (p.keeper, Item.id p.item, p.amount_milli)
    | E.Snapshot _
    | E.Payout_owed _
    | E.Candidates _
    | E.Unattributed _
    | E.Paid _
    | E.Payout_failed _ -> None)
;;

let replay_in_fresh_process config keeper =
  Eio_unix.run_in_systhread (fun () ->
    let channel =
      Unix.open_process_args_in
        Sys.executable_name
        [| Sys.executable_name
         ; "--replay-candle-account"
         ; config.Workspace.base_path
         ; keeper
        |]
    in
    let output = In_channel.input_all channel in
    match Unix.close_process_in channel with
    | Unix.WEXITED 0 -> Yojson.Safe.from_string output
    | _ -> failf "fresh process could not replay the account: %s" output)
;;

let test_tool_purchase_and_restart () =
  with_workspace (fun _ _ config ->
    credit config ~goal:"goal-a" ~keeper:"keeper-a" 1000;
    credit config ~goal:"goal-b" ~keeper:"keeper-b" 500;
    let before = balance config "keeper-a" in
    check
      int
      "actual Keeper owns its credit"
      1000
      U.(member "balance_milli" before |> to_string |> int_of_string);
    check
      string
      "the Keeper turn selects its wallet"
      "keeper-a"
      U.(member "keeper" before |> to_string);
    let receipt = buy config "keeper-a" "glasses" |> succeeded in
    check int "configured price was paid" 400 U.(member "amount_milli" receipt |> to_string |> int_of_string);
    check
      int
      "atomic receipt includes the remaining balance"
      600
      U.(member "account" receipt |> member "balance_milli" |> to_string |> int_of_string);
    check
      (list string)
      "purchase owns the canonical item"
      [ "glasses" ]
      U.(
        member "account" receipt |> member "owned_items" |> to_list |> List.map to_string);
    check
      int
      "another Keeper's wallet is untouched"
      500
      U.(member "balance_milli" (balance config "keeper-b") |> to_string |> int_of_string);
    rejected "already_owned" (buy config "keeper-a" "glasses");
    let committed = bytes config in
    rejected
      "invalid_arguments"
      (call
         config
         "keeper-a"
         "keeper_candle_purchase"
         (`Assoc [ "item", `String "medal"; "keeper", `String "keeper-b" ]));
    check string "a target argument changes no account" committed (bytes config);
    write_config config "\n[shop.prices_milli]\nglasses = 900\n";
    let replayed = replay_in_fresh_process config "keeper-a" in
    check
      int
      "fresh process replays the stored debit, not today's price"
      600
      U.(member "balance_milli" replayed |> to_string |> int_of_string);
    check
      (list string)
      "fresh process restores ownership"
      [ "glasses" ]
      U.(member "owned_items" replayed |> to_list |> List.map to_string);
    check int "repeated purchase appended no duplicate" 1 (List.length (purchases config)))
;;

let concurrent_buy config ~initial ~first ~second ~remaining ~retry_code =
  credit config ~goal:"concurrent-goal" ~keeper:"keeper-a" initial;
  let start, release = Eio.Promise.create () in
  let results =
    Eio.Fiber.pair
      (fun () ->
         Eio.Promise.resolve release ();
         buy config "keeper-a" first)
      (fun () ->
         Eio.Promise.await start;
         buy config "keeper-a" second)
  in
  let successful (r : Keeper_tool_execution.t) =
    match r.disposition with
    | Tool_result.Completed () -> true
    | Tool_result.Failed _ | Tool_result.Deferred () -> false
  in
  let left, right = results in
  check
    int
    "only one concurrent purchase committed"
    1
    (List.length (List.filter successful [ left; right ]));
  check int "ledger has exactly one debit" 1 (List.length (purchases config));
  let account = balance config "keeper-a" in
  check
    int
    "concurrent requests cannot overspend"
    remaining
    U.(member "balance_milli" account |> to_string |> int_of_string);
  check
    int
    "only the committed item became owned"
    1
    U.(member "owned_items" account |> to_list |> List.length);
  let failed_item = if successful left then second else first in
  rejected retry_code (buy config "keeper-a" failed_item)
;;

let test_concurrent_distinct_purchases () =
  with_workspace (fun _ _ config ->
    concurrent_buy
      config
      ~initial:1000
      ~first:"medal"
      ~second:"crown"
      ~remaining:300
      ~retry_code:"insufficient_balance")
;;

let test_concurrent_same_purchase () =
  with_workspace (fun _ _ config ->
    concurrent_buy
      config
      ~initial:2000
      ~first:"medal"
      ~second:"medal"
      ~remaining:1300
      ~retry_code:"already_owned")
;;

let test_explicit_prices_and_unpriced_items () =
  with_workspace (fun _ _ config ->
    credit config ~goal:"price-goal" ~keeper:"keeper-a" 1000;
    write_config config "";
    let catalog =
      call config "keeper-a" "keeper_candle_catalog" (`Assoc []) |> succeeded
    in
    let items = U.(member "items" catalog |> to_list) in
    check
      int
      "catalog is exactly the renderer's canonical catalog"
      (List.length Item.all)
      (List.length items);
    check
      bool
      "no price is invented"
      true
      (List.for_all (fun row -> U.member "price_status" row = `String "unpriced") items);
    let original = bytes config in
    rejected "unpriced_item" (buy config "keeper-a" "glasses");
    List.iter
      (fun shop ->
         write_config config shop;
         rejected "candle_disabled" (buy config "keeper-a" "glasses");
         check string "invalid policy cannot mutate the ledger" original (bytes config))
      [ "\n[shop.prices_milli]\nglasses = -1\n"
      ; "\n[shop.prices_milli]\nglasses = 1.5\n"
      ; "\n[shop.prices_milli]\nunknown_item = 100\n"
      ; "\n[shop.prices_milli]\nbare_face = 100\n"
      ; "\n[shop]\n"
      ];
    write_config config "\n[shop.prices_milli]\nglasses = 0\n";
    ignore (buy config "keeper-a" "glasses" |> succeeded);
    check
      int
      "an explicit zero price grants ownership without minting money"
      1000
      U.(member "balance_milli" (balance config "keeper-a") |> to_string |> int_of_string);
    rejected "already_owned" (buy config "keeper-a" "glasses"))
;;

let test_large_tool_amounts_remain_exact () =
  with_workspace (fun _ _ config ->
    let amount = 9_007_199_254_740_993 in
    (* Each payout stays within Candle_math's checked multiplication range;
       their combined wallet crosses JavaScript's safe-integer boundary. *)
    credit config ~goal:"large-wallet-a" ~keeper:"keeper-a" 4_503_599_627_370_497;
    credit config ~goal:"large-wallet-b" ~keeper:"keeper-a" 4_503_599_627_370_496;
    write_config config
      ("\n[shop.prices_milli]\nglasses = " ^ string_of_int amount ^ "\n");
    let account = balance config "keeper-a" in
    check string "large wallet is a decimal string" (string_of_int amount)
      U.(member "balance_milli" account |> to_string);
    let catalog =
      call config "keeper-a" "keeper_candle_catalog" (`Assoc []) |> succeeded in
    let glasses = U.(member "items" catalog |> to_list)
      |> List.find (fun row -> U.(member "id" row |> to_string) = "glasses") in
    check string "large price is a decimal string" (string_of_int amount)
      U.(member "price_milli" glasses |> to_string);
    let receipt = buy config "keeper-a" "glasses" |> succeeded in
    check string "large debit is a decimal string" (string_of_int amount)
      U.(member "amount_milli" receipt |> to_string);
    check string "remaining balance is exact zero" "0"
      U.(member "account" receipt |> member "balance_milli" |> to_string))
;;

let test_corruption_and_partial_tail_are_read_only () =
  with_workspace (fun _ _ config ->
    credit config ~goal:"corruption-goal" ~keeper:"keeper-a" 1000;
    let valid = bytes config in
    let invalid_purchase =
      `Assoc
        [ "kind", `String "purchased"
        ; "at", Candle_time.to_yojson at
        ; "keeper", `String "keeper-a"
        ; "item", `String "glasses"
        ; "amount_milli", `Int 2000
        ]
    in
    List.iter
      (fun (suffix, expected) ->
         let original = valid ^ suffix in
         Fs_compat.save_file (ledger_path config) original;
         rejected expected (call config "keeper-a" "keeper_candle_balance" (`Assoc []));
         rejected expected (buy config "keeper-a" "glasses");
         ignore (call config "keeper-a" "keeper_candle_catalog" (`Assoc []) |> succeeded);
         check
           string
           "read/catalog/purchase never repair a damaged ledger"
           original
           (bytes config))
      [ "{\"kind\":\"purchased\"", "ledger_unavailable"
      ; "{\"kind\":\"unknown\"}\n", "ledger_unavailable"
      ; Yojson.Safe.to_string invalid_purchase ^ "\n", "account_invalid"
      ])
;;

let test_keeper_dispatch_and_mcp_use_trusted_self () =
  with_workspace (fun env sw config ->
    credit config ~goal:"identity-a" ~keeper:"keeper-a" 1000;
    credit config ~goal:"identity-b" ~keeper:"keeper-b" 500;
    let fallback =
      match
        Keeper_tag_dispatch.dispatch
          ~config
          ~keeper_name:"keeper-a"
          ~agent_name:"keeper-b"
          ~tag:Tool_dispatch.Mod_misc
          ~name:"keeper_candle_balance"
          ~args:(`Assoc [])
      with
      | Some result -> result
      | None -> fail "Keeper tag route omitted Candle"
    in
    check bool "Keeper tag route succeeds" true (Tool_result.is_success fallback);
    check
      string
      "stable Keeper overrides its task actor"
      "keeper-a"
      U.(member "keeper" (Tool_result.data fallback) |> to_string);
    let stored_meta = meta "keeper-a" in
    let meta_path = Keeper_types_profile.keeper_meta_path config "keeper-a" in
    Fs_compat.mkdir_p (Filename.dirname meta_path);
    Fs_compat.save_file
      meta_path
      (Yojson.Safe.to_string (Keeper_meta_json.meta_to_json stored_meta));
    let token =
      match
        Auth.create_token config.base_path ~agent_name:"keeper-a" ~role:Masc_domain.Worker
      with
      | Ok (token, _) -> token
      | Error error -> fail (Masc_domain.masc_error_to_string error)
    in
    let state = Mcp_server_eio.For_testing.create_state ~base_path:config.base_path () in
    let mcp ?auth_token args =
      Mcp_server_eio.execute_tool_eio
        ~sw
        ~clock:(Eio.Stdenv.clock env)
        ~workspace_scope:(Mcp_server.workspace_scope state)
        ?auth_token
        state
        ~name:"keeper_candle_balance"
        ~arguments:args
    in
    let own = mcp ~auth_token:token (`Assoc []) in
    check
      bool
      ("authenticated Keeper reaches Candle: " ^ Tool_result.message own)
      true
      (Tool_result.is_success own);
    check
      string
      "bearer owner selects its wallet"
      "keeper-a"
      U.(member "keeper" (Tool_result.data own) |> to_string);
    let spoof = mcp (`Assoc [ "_agent_name", `String "keeper-a" ]) in
    check
      bool
      "a self-declared name cannot select a wallet"
      false
      (Tool_result.is_success spoof);
    let other = mcp ~auth_token:token (`Assoc [ "keeper", `String "keeper-b" ]) in
    check
      bool
      "wallet targets are not accepted arguments"
      false
      (Tool_result.is_success other);
    check
      int
      "identity probes did not debit either wallet"
      0
      (List.length (purchases config)))
;;

let test_tool_surface_is_eager () =
  List.iter
    (fun name ->
       check
         bool
         (name ^ " is visible on the Keeper surface")
         true
         (List.exists
            (fun (schema : Masc_domain.tool_schema) -> schema.name = name)
            (Keeper_tool_descriptor.model_visible_schemas ()));
       check
         bool
         (name ^ " is always loaded")
         true
         (Keeper_tool_descriptor.declared_loading_of_model_name name
          = Tool_definition_toml.Always_loaded))
    [ "keeper_candle_balance"; "keeper_candle_catalog"; "keeper_candle_purchase" ]
;;

let () =
  match Array.to_list Sys.argv with
  | [ _; "--replay-candle-account"; base_path; keeper_name ] ->
    Candle_status.install_appraiser_check (fun () -> Ok ());
    let result =
      Keeper_candle_tools.handle
        ~operation:Keeper_candle_tools.Balance
        ~base_path
        ~keeper_name
        ~tool_name:"keeper_candle_balance"
        ~start_time:(Tool_timing.start ())
        ~args:(`Assoc [])
    in
    if Tool_result.is_success result
    then print_endline (Yojson.Safe.to_string (Tool_result.data result))
    else (
      prerr_endline (Tool_result.message result);
      exit 1)
  | _ ->
    run
      "candle_purchase_flow"
      [ ( "public tools and ledger"
        , [ test_case
              "purchase debits self and survives a process restart"
              `Quick
              test_tool_purchase_and_restart
          ; test_case
              "concurrent different items cannot overspend"
              `Quick
              test_concurrent_distinct_purchases
          ; test_case
              "concurrent duplicate purchase cannot charge twice"
              `Quick
              test_concurrent_same_purchase
          ; test_case
              "prices are explicit and missing items remain unpriced"
              `Quick
              test_explicit_prices_and_unpriced_items
          ; test_case
              "large tool amounts stay exact decimal strings"
              `Quick
              test_large_tool_amounts_remain_exact
          ; test_case
              "corrupt rows and partial tails are never repaired by reads or purchase"
              `Quick
              test_corruption_and_partial_tail_are_read_only
          ; test_case
              "Keeper and authenticated MCP routes use trusted self"
              `Quick
              test_keeper_dispatch_and_mcp_use_trusted_self
          ; test_case
              "balance catalog and purchase are eager Keeper tools"
              `Quick
              test_tool_surface_is_eager
          ] )
      ]
;;
