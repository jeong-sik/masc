(** Adversarial-review coverage for #25582: the [Api (InvalidRequest _)] class
    is exempt from crash accounting via [is_auto_recoverable_turn_error], so
    it must carry its own bounded compensating accounting
    ([Keeper_unified_turn_failure.note_invalid_request_failure]) instead of
    retrying the same deterministic 400 forever with [consecutive] pinned at
    0. *)

open Alcotest

module EC = Masc.Keeper_error_classify
module KUF = Masc.Keeper_unified_turn_failure

let rec rm_rf path =
  if Sys.file_exists path
  then if Sys.is_directory path
    then (
      Sys.readdir path
      |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path)
    else Sys.remove path
;;

let with_temp_dir prefix f =
  let dir = Filename.temp_file prefix "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)
;;

let invalid_request message =
  Agent_core.Error.Api
    (Llm_provider.Retry.InvalidRequest
       { message; reason = Llm_provider.Retry.Unknown_invalid_request })
;;

let test_is_invalid_request_error_only_for_api_invalid_request () =
  check
    bool
    "Api InvalidRequest matches"
    true
    (EC.is_invalid_request_error (invalid_request "bad body"));
  check
    bool
    "provider-side InvalidRequest does not match"
    false
    (EC.is_invalid_request_error
       (Agent_core.Error.Provider
          (Llm_provider.Error.InvalidRequest
             { provider = "provider"; reason = "Invalid request: bad body" })));
  check
    bool
    "ContextOverflow does not match"
    false
    (EC.is_invalid_request_error
       (Agent_core.Error.Api
          (ContextOverflow { message = "exceeded"; limit = None })));
  check
    bool
    "rendered internal text does not match"
    false
    (EC.is_invalid_request_error
       (Agent_core.Error.Internal "Bad Request: arbitrary provider text"))
;;

let test_invalid_request_is_auto_recoverable () =
  check
    bool
    "Api InvalidRequest is auto-recoverable at turn level"
    true
    (EC.is_auto_recoverable_turn_error (invalid_request "bad body"))
;;

let test_transport_400_bridges_to_typed_api_invalid_request () =
  let classified =
    Llm_provider.Retry.classify_error
      ~retry_after_header:None
      ~status:400
      ~body:"transport rejection"
  in
  match classified with
  | Llm_provider.Retry.InvalidRequest _ ->
    check
      bool
      "transport-classified 400 reaches the typed API predicate"
      true
      (EC.is_invalid_request_error (Agent_core.Error.Api classified))
  | _ ->
    fail "HTTP 400 transport classification did not produce InvalidRequest"
;;

let test_consecutive_counter_bounds_exemption () =
  with_temp_dir "invalid-request-bounded" @@ fun base_path ->
  let keeper = "test-ir-bounded" in
  for i = 1 to KUF.max_consecutive_invalid_request_failures do
    check
      bool
      (Printf.sprintf "attempt %d stays exempt from crash accounting" i)
      false
      (KUF.note_invalid_request_failure ~base_path ~keeper_name:keeper)
  done;
  check
    bool
    "attempt beyond the bound degrades to crash accounting"
    true
    (KUF.note_invalid_request_failure ~base_path ~keeper_name:keeper);
  check
    bool
    "degradation persists while failures continue"
    true
    (KUF.note_invalid_request_failure ~base_path ~keeper_name:keeper);
  check bool "durable reset commits" true
    (KUF.reset_failure_exemptions ~base_path ~keeper_name:keeper);
  check
    bool
    "reset after success/operator clear restores the exemption budget"
    false
    (KUF.note_invalid_request_failure ~base_path ~keeper_name:keeper)
;;

let test_counters_are_per_keeper () =
  with_temp_dir "invalid-request-isolation" @@ fun base_path ->
  let keeper_a = "test-ir-a" in
  let keeper_b = "test-ir-b" in
  for _ = 1 to KUF.max_consecutive_invalid_request_failures + 1 do
    ignore (KUF.note_invalid_request_failure ~base_path ~keeper_name:keeper_a)
  done;
  check
    bool
    "keeper A exhausted its budget"
    true
    (KUF.note_invalid_request_failure ~base_path ~keeper_name:keeper_a);
  check
    bool
    "keeper B budget is unaffected"
    false
    (KUF.note_invalid_request_failure ~base_path ~keeper_name:keeper_b)
;;

let test_counter_survives_process_boundary () =
  with_temp_dir "invalid-request-restart" @@ fun base_path ->
  let keeper_name = "test-ir-restart" in
  for i = 1 to KUF.max_consecutive_invalid_request_failures do
    check
      bool
      (Printf.sprintf "pre-restart attempt %d stays exempt" i)
      false
      (KUF.note_invalid_request_failure ~base_path ~keeper_name)
  done;
  (match Masc.Keeper_failure_exemption_store.load ~base_path ~keeper_name with
   | Ok (Some { invalid_request_count = 3; empty_completion_count = 0 }) -> ()
   | _ -> fail "durable pre-restart budget was not three");
  check
    bool
    "first post-restart observation exhausts the carried budget"
    true
    (KUF.note_invalid_request_failure ~base_path ~keeper_name);
  match Masc.Keeper_failure_exemption_store.load ~base_path ~keeper_name with
  | Ok (Some { invalid_request_count = 4; empty_completion_count = 0 }) -> ()
  | _ -> fail "durable post-restart budget was not four"
;;

let test_unknown_schema_fails_closed () =
  with_temp_dir "invalid-request-schema" @@ fun base_path ->
  let keeper_name = "test-ir-schema" in
  ignore (KUF.note_invalid_request_failure ~base_path ~keeper_name);
  let path =
    Masc.Keeper_failure_exemption_store.path_for ~base_path ~keeper_name
  in
  Out_channel.with_open_bin path (fun channel ->
    output_string
      channel
      {|{"schema":"keeper.failure_exemptions.v0","invalid_request_count":0,"empty_completion_count":9}|});
  check
    bool
    "unknown durable schema cannot grant an exemption"
    true
    (KUF.note_invalid_request_failure ~base_path ~keeper_name)
;;

let () =
  run
    "keeper_invalid_request_auto_recover"
    [ ( "invalid_request"
      , [ test_case
            "is_invalid_request_error only matches Api InvalidRequest"
            `Quick
            test_is_invalid_request_error_only_for_api_invalid_request
        ; test_case
            "Api InvalidRequest is auto-recoverable"
            `Quick
            test_invalid_request_is_auto_recoverable
        ; test_case
            "HTTP 400 transport classification bridges to typed Api InvalidRequest"
            `Quick
            test_transport_400_bridges_to_typed_api_invalid_request
        ; test_case
            "consecutive counter bounds the crash-accounting exemption"
            `Quick
            test_consecutive_counter_bounds_exemption
        ; test_case
            "consecutive counters are per-keeper"
            `Quick
            test_counters_are_per_keeper
        ; test_case
            "counter survives process boundary"
            `Quick
            test_counter_survives_process_boundary
        ; test_case
            "unknown schema fails closed"
            `Quick
            test_unknown_schema_fails_closed
        ] )
    ]
;;
