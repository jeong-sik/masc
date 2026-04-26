(** Test_agent_economy — Unit tests for Agent Economy Phase 1

    Tests: configuration, earn/spend, balance tracking,
    pressure mode transitions, reputation multiplier,
    JSONL ledger persistence, and feature flag gating.
*)

(* Workaround: stale opam-installed masc_mcp shadows the local library's
   wrapper module. Use direct module alias instead of open Masc_mcp. *)
module Agent_economy = Masc_mcp__Agent_economy

let () = Mirage_crypto_rng_unix.use_default ()

(** {1 Test Helpers} *)

let fresh_tmpdir () =
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-economy-test-%d-%d" (Unix.getpid ()) (Random.int 1_000_000))
  in
  Unix.mkdir dir 0o755;
  dir
;;

let rm_rf dir =
  let rec remove path =
    if Sys.is_directory path
    then (
      Array.iter (fun f -> remove (Filename.concat path f)) (Sys.readdir path);
      Unix.rmdir path)
    else Sys.remove path
  in
  if Sys.file_exists dir then remove dir
;;

let with_env key value f =
  let prev = Sys.getenv_opt key in
  Unix.putenv key value;
  let result =
    try f () with
    | e ->
      (match prev with
       | Some v -> Unix.putenv key v
       | None -> (* best-effort unset *) Unix.putenv key "");
      raise e
  in
  (match prev with
   | Some v -> Unix.putenv key v
   | None -> Unix.putenv key "");
  result
;;

let with_economy_enabled f = with_env "MASC_ECONOMY_ENABLED" "true" f

(** Reset balance cache between tests *)
let reset_cache () = Agent_economy.reset_cache ()

(** {1 Configuration Tests} *)

let test_feature_flag_default () =
  with_env "MASC_ECONOMY_ENABLED" "false" (fun () ->
    Alcotest.(check bool) "default disabled" false (Agent_economy.enabled ()))
;;

let test_feature_flag_enabled () =
  with_env "MASC_ECONOMY_ENABLED" "true" (fun () ->
    Alcotest.(check bool) "enabled" true (Agent_economy.enabled ()))
;;

let test_initial_balance_default () =
  with_env "MASC_ECONOMY_INITIAL_BALANCE" "5.0" (fun () ->
    let b = Agent_economy.initial_balance () in
    Alcotest.(check (float 0.01)) "default 5.0" 5.0 b)
;;

let test_initial_balance_custom () =
  with_env "MASC_ECONOMY_INITIAL_BALANCE" "42.0" (fun () ->
    let b = Agent_economy.initial_balance () in
    Alcotest.(check (float 0.01)) "custom 42.0" 42.0 b)
;;

(** {1 Pressure Mode Tests} *)

let test_pressure_normal () =
  let dir = fresh_tmpdir () in
  reset_cache ();
  with_economy_enabled (fun () ->
    with_env "MASC_ECONOMY_INITIAL_BALANCE" "10.0" (fun () ->
      with_env "MASC_ECONOMY_FRUGAL_THRESHOLD" "5.0" (fun () ->
        let mode =
          Agent_economy.economic_pressure ~base_path:dir ~agent_name:"rich-agent"
        in
        Alcotest.(check string)
          "normal mode"
          "normal"
          (Agent_economy.pressure_mode_to_string mode))));
  rm_rf dir
;;

let test_pressure_frugal () =
  let dir = fresh_tmpdir () in
  reset_cache ();
  with_economy_enabled (fun () ->
    with_env "MASC_ECONOMY_INITIAL_BALANCE" "3.0" (fun () ->
      with_env "MASC_ECONOMY_FRUGAL_THRESHOLD" "5.0" (fun () ->
        with_env "MASC_ECONOMY_HUSTLE_THRESHOLD" "0.0" (fun () ->
          let mode =
            Agent_economy.economic_pressure ~base_path:dir ~agent_name:"careful-agent"
          in
          Alcotest.(check string)
            "frugal mode"
            "frugal"
            (Agent_economy.pressure_mode_to_string mode)))));
  rm_rf dir
;;

let test_pressure_hustle () =
  let dir = fresh_tmpdir () in
  reset_cache ();
  with_economy_enabled (fun () ->
    with_env "MASC_ECONOMY_INITIAL_BALANCE" "-1.0" (fun () ->
      with_env "MASC_ECONOMY_HUSTLE_THRESHOLD" "0.0" (fun () ->
        let mode =
          Agent_economy.economic_pressure ~base_path:dir ~agent_name:"broke-agent"
        in
        Alcotest.(check string)
          "hustle mode"
          "hustle"
          (Agent_economy.pressure_mode_to_string mode))));
  rm_rf dir
;;

let test_pressure_disabled () =
  let dir = fresh_tmpdir () in
  reset_cache ();
  with_env "MASC_ECONOMY_ENABLED" "false" (fun () ->
    let mode = Agent_economy.economic_pressure ~base_path:dir ~agent_name:"any-agent" in
    Alcotest.(check string)
      "always normal when disabled"
      "normal"
      (Agent_economy.pressure_mode_to_string mode));
  rm_rf dir
;;

(** {1 Earn/Spend Tests} *)

let test_earn_task_done () =
  let dir = fresh_tmpdir () in
  reset_cache ();
  with_economy_enabled (fun () ->
    with_env "MASC_ECONOMY_INITIAL_BALANCE" "5.0" (fun () ->
      with_env "MASC_ECONOMY_REWARD_TASK_DONE" "10.0" (fun () ->
        with_env "MASC_ECONOMY_REPUTATION_MULTIPLIER" "false" (fun () ->
          match
            Agent_economy.earn
              ~base_path:dir
              ~agent_name:"worker"
              ~kind:Earn_task_done
              ~reason:"completed task-001"
              ()
          with
          | Error msg -> Alcotest.fail msg
          | Ok balance -> Alcotest.(check (float 0.01)) "5.0 + 10.0 = 15.0" 15.0 balance))));
  rm_rf dir
;;

let test_spend_model_call () =
  let dir = fresh_tmpdir () in
  reset_cache ();
  with_economy_enabled (fun () ->
    with_env "MASC_ECONOMY_INITIAL_BALANCE" "10.0" (fun () ->
      match
        Agent_economy.spend
          ~base_path:dir
          ~agent_name:"spender"
          ~amount:0.05
          ~kind:Spend_model_call
          ~reason:"glm call"
          ()
      with
      | Error msg -> Alcotest.fail msg
      | Ok balance -> Alcotest.(check (float 0.001)) "10.0 - 0.05 = 9.95" 9.95 balance));
  rm_rf dir
;;

let test_earn_when_disabled () =
  let dir = fresh_tmpdir () in
  reset_cache ();
  with_env "MASC_ECONOMY_ENABLED" "false" (fun () ->
    with_env "MASC_ECONOMY_INITIAL_BALANCE" "5.0" (fun () ->
      match
        Agent_economy.earn
          ~base_path:dir
          ~agent_name:"agent"
          ~kind:Earn_task_done
          ~reason:"should no-op"
          ()
      with
      | Error msg -> Alcotest.fail msg
      | Ok balance -> Alcotest.(check (float 0.01)) "unchanged when disabled" 5.0 balance));
  rm_rf dir
;;

let test_multiple_transactions () =
  let dir = fresh_tmpdir () in
  reset_cache ();
  with_economy_enabled (fun () ->
    with_env "MASC_ECONOMY_INITIAL_BALANCE" "0.0" (fun () ->
      with_env "MASC_ECONOMY_REWARD_TASK_DONE" "10.0" (fun () ->
        with_env "MASC_ECONOMY_REPUTATION_MULTIPLIER" "false" (fun () ->
          (* Earn twice *)
          (match
             Agent_economy.earn
               ~base_path:dir
               ~agent_name:"multi"
               ~kind:Earn_task_done
               ~reason:"task-1"
               ()
           with
           | Error msg -> Alcotest.fail msg
           | Ok b -> Alcotest.(check (float 0.01)) "first earn" 10.0 b);
          (match
             Agent_economy.earn
               ~base_path:dir
               ~agent_name:"multi"
               ~kind:Earn_task_done
               ~reason:"task-2"
               ()
           with
           | Error msg -> Alcotest.fail msg
           | Ok b -> Alcotest.(check (float 0.01)) "second earn" 20.0 b);
          (* Spend *)
          (match
             Agent_economy.spend
               ~base_path:dir
               ~agent_name:"multi"
               ~amount:3.0
               ~kind:Spend_model_call
               ~reason:"big call"
               ()
           with
           | Error msg -> Alcotest.fail msg
           | Ok b -> Alcotest.(check (float 0.01)) "after spend" 17.0 b);
          (* Check balance *)
          let bal = Agent_economy.get_balance ~base_path:dir ~agent_name:"multi" in
          Alcotest.(check (float 0.01)) "final balance" 17.0 bal))));
  rm_rf dir
;;

(** {1 Ledger Persistence Tests} *)

let test_ledger_persistence () =
  let dir = fresh_tmpdir () in
  reset_cache ();
  with_economy_enabled (fun () ->
    with_env "MASC_ECONOMY_INITIAL_BALANCE" "5.0" (fun () ->
      with_env "MASC_ECONOMY_REWARD_BOARD_POST" "1.0" (fun () ->
        with_env "MASC_ECONOMY_REPUTATION_MULTIPLIER" "false" (fun () ->
          ignore
            (Agent_economy.earn
               ~base_path:dir
               ~agent_name:"poster"
               ~kind:Earn_board_post
               ~reason:"wrote post"
               ());
          (* Reset cache to simulate restart *)
          reset_cache ();
          let bal = Agent_economy.get_balance ~base_path:dir ~agent_name:"poster" in
          Alcotest.(check (float 0.01)) "persisted after reload" 6.0 bal))));
  rm_rf dir
;;

let test_ledger_file_created () =
  let dir = fresh_tmpdir () in
  reset_cache ();
  with_economy_enabled (fun () ->
    with_env "MASC_ECONOMY_REPUTATION_MULTIPLIER" "false" (fun () ->
      ignore
        (Agent_economy.earn
           ~base_path:dir
           ~agent_name:"writer"
           ~kind:Earn_board_post
           ~reason:"test"
           ());
      let path =
        Filename.concat
          (Filename.concat (Filename.concat dir Common.masc_dirname) "economy")
          "ledger.jsonl"
      in
      Alcotest.(check bool) "ledger file exists" true (Sys.file_exists path)));
  rm_rf dir
;;

let test_list_transactions () =
  let dir = fresh_tmpdir () in
  reset_cache ();
  with_economy_enabled (fun () ->
    with_env "MASC_ECONOMY_REPUTATION_MULTIPLIER" "false" (fun () ->
      ignore
        (Agent_economy.earn
           ~base_path:dir
           ~agent_name:"reader"
           ~kind:Earn_task_done
           ~reason:"task done"
           ~metadata:(`Assoc [ "goal_id", `String "goal-1" ])
           ());
      ignore
        (Agent_economy.spend
           ~base_path:dir
           ~agent_name:"reader"
           ~amount:0.25
           ~kind:Spend_model_call
           ~reason:"model call"
           ());
      let txns = Agent_economy.list_transactions ~base_path:dir in
      Alcotest.(check int) "transaction count" 2 (List.length txns);
      let first = List.hd txns in
      let open Yojson.Safe.Util in
      Alcotest.(check string)
        "metadata goal id"
        "goal-1"
        (first.metadata |> member "goal_id" |> to_string)));
  rm_rf dir
;;

(** {1 Reputation Multiplier Tests} *)

let test_reward_multiplier_range () =
  (* score=0.0 -> 0.5x, score=0.5 -> 1.0x, score=1.0 -> 1.5x *)
  let m0 = Agent_economy.reward_multiplier ~overall_score:0.0 in
  let m5 = Agent_economy.reward_multiplier ~overall_score:0.5 in
  let m10 = Agent_economy.reward_multiplier ~overall_score:1.0 in
  Alcotest.(check (float 0.01)) "score 0.0 -> 0.5x" 0.5 m0;
  Alcotest.(check (float 0.01)) "score 0.5 -> 1.0x" 1.0 m5;
  Alcotest.(check (float 0.01)) "score 1.0 -> 1.5x" 1.5 m10
;;

let test_reward_multiplier_clamped () =
  let m_neg = Agent_economy.reward_multiplier ~overall_score:(-0.5) in
  let m_over = Agent_economy.reward_multiplier ~overall_score:2.0 in
  Alcotest.(check (float 0.01)) "negative clamped to 0.5x" 0.5 m_neg;
  Alcotest.(check (float 0.01)) "over 1.0 clamped to 1.5x" 1.5 m_over
;;

(** {1 Serialization Tests} *)

let test_transaction_roundtrip () =
  let txn : Agent_economy.transaction =
    { id = "txn-deadbeef"
    ; agent_name = "test-agent"
    ; kind = Earn_task_done
    ; amount = 10.0
    ; balance_after = 15.0
    ; reason = "completed task"
    ; counterparty = "system"
    ; metadata = `Null
    ; timestamp = 1000.0
    }
  in
  let json = Agent_economy.transaction_to_json txn in
  match Agent_economy.transaction_of_json json with
  | None -> Alcotest.fail "roundtrip deserialization failed"
  | Some decoded ->
    Alcotest.(check string) "id" txn.id decoded.id;
    Alcotest.(check string) "agent" txn.agent_name decoded.agent_name;
    Alcotest.(check (float 0.01)) "amount" txn.amount decoded.amount;
    Alcotest.(check (float 0.01)) "balance" txn.balance_after decoded.balance_after
;;

let test_transaction_invalid_json () =
  let json = `Assoc [ "id", `String "" ] in
  match Agent_economy.transaction_of_json json with
  | None -> ()
  | Some _ -> Alcotest.fail "should reject empty id"
;;

(** {1 Pressure Mode Transition After Spending} *)

let test_pressure_transition_after_spend () =
  let dir = fresh_tmpdir () in
  reset_cache ();
  with_economy_enabled (fun () ->
    with_env "MASC_ECONOMY_INITIAL_BALANCE" "6.0" (fun () ->
      with_env "MASC_ECONOMY_FRUGAL_THRESHOLD" "5.0" (fun () ->
        with_env "MASC_ECONOMY_HUSTLE_THRESHOLD" "0.0" (fun () ->
          (* Start: 6.0 -> Normal *)
          let m1 =
            Agent_economy.economic_pressure ~base_path:dir ~agent_name:"transitioning"
          in
          Alcotest.(check string)
            "starts normal"
            "normal"
            (Agent_economy.pressure_mode_to_string m1);
          (* Spend 3.0 -> 3.0 -> Frugal *)
          ignore
            (Agent_economy.spend
               ~base_path:dir
               ~agent_name:"transitioning"
               ~amount:3.0
               ~kind:Spend_model_call
               ~reason:"big call"
               ());
          let m2 =
            Agent_economy.economic_pressure ~base_path:dir ~agent_name:"transitioning"
          in
          Alcotest.(check string)
            "now frugal"
            "frugal"
            (Agent_economy.pressure_mode_to_string m2);
          (* Spend 4.0 -> -1.0 -> Hustle *)
          ignore
            (Agent_economy.spend
               ~base_path:dir
               ~agent_name:"transitioning"
               ~amount:4.0
               ~kind:Spend_model_call
               ~reason:"huge call"
               ());
          let m3 =
            Agent_economy.economic_pressure ~base_path:dir ~agent_name:"transitioning"
          in
          Alcotest.(check string)
            "now hustle"
            "hustle"
            (Agent_economy.pressure_mode_to_string m3)))));
  rm_rf dir
;;

(** {1 Test Suite} *)

let () =
  Alcotest.run
    "Agent Economy"
    [ ( "config"
      , [ Alcotest.test_case "feature flag default" `Quick test_feature_flag_default
        ; Alcotest.test_case "feature flag enabled" `Quick test_feature_flag_enabled
        ; Alcotest.test_case "initial balance default" `Quick test_initial_balance_default
        ; Alcotest.test_case "initial balance custom" `Quick test_initial_balance_custom
        ] )
    ; ( "pressure"
      , [ Alcotest.test_case "normal mode" `Quick test_pressure_normal
        ; Alcotest.test_case "frugal mode" `Quick test_pressure_frugal
        ; Alcotest.test_case "hustle mode" `Quick test_pressure_hustle
        ; Alcotest.test_case "disabled -> always normal" `Quick test_pressure_disabled
        ; Alcotest.test_case
            "transition after spend"
            `Quick
            test_pressure_transition_after_spend
        ] )
    ; ( "earn_spend"
      , [ Alcotest.test_case "earn task done" `Quick test_earn_task_done
        ; Alcotest.test_case "spend model call" `Quick test_spend_model_call
        ; Alcotest.test_case "earn when disabled" `Quick test_earn_when_disabled
        ; Alcotest.test_case "multiple transactions" `Quick test_multiple_transactions
        ] )
    ; ( "persistence"
      , [ Alcotest.test_case "ledger persistence" `Quick test_ledger_persistence
        ; Alcotest.test_case "ledger file created" `Quick test_ledger_file_created
        ; Alcotest.test_case "list transactions" `Quick test_list_transactions
        ] )
    ; ( "reputation"
      , [ Alcotest.test_case "multiplier range" `Quick test_reward_multiplier_range
        ; Alcotest.test_case "multiplier clamped" `Quick test_reward_multiplier_clamped
        ] )
    ; ( "serialization"
      , [ Alcotest.test_case "transaction roundtrip" `Quick test_transaction_roundtrip
        ; Alcotest.test_case "invalid json rejected" `Quick test_transaction_invalid_json
        ] )
    ]
;;
