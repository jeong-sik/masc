open Alcotest

module Store = Channel_gate_binding_store
module U = Yojson.Safe.Util

let temp_dir_counter = ref 0

let with_temp_dir f =
  incr temp_dir_counter;
  let base =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "channel-gate-binding-store-%d-%06d" (Unix.getpid ())
         !temp_dir_counter)
  in
  Unix.mkdir base 0o755;
  Fun.protect
    ~finally:(fun () ->
      let rec rm_rf path =
        if Sys.file_exists path then
          if Sys.is_directory path then (
            Sys.readdir path
            |> Array.iter (fun name -> rm_rf (Filename.concat path name));
            Unix.rmdir path
          ) else Sys.remove path
      in
      rm_rf base)
    (fun () -> f base)

let store_for_dir dir ~guild_id_field =
  let binding_path = Filename.concat dir "bindings.json" in
  let audit_path = Filename.concat dir "binding_audit.jsonl" in
  Store.create
    ~binding_store_path:(fun () -> binding_path)
    ~binding_store_read_path:(fun () -> binding_path)
    ~binding_audit_path:(fun () -> audit_path)
    ~binding_audit_read_path:(fun () -> audit_path)
    ~guild_id_field

let sample_event ?guild_id ~action () =
  Store.
    {
      timestamp = "2026-07-01T00:00:00Z";
      action;
      guild_id;
      channel_id = "channel-1";
      keeper_name = "luna";
      actor_id = "dashboard";
      actor_name = "dashboard";
      previous_keeper = "";
    }

let test_normalizes_bindings_json () =
  let bindings =
    Store.normalize_bindings_json
      (`Assoc
        [
          ("z-channel", `String "luna");
          ("a-channel", `String "arya");
        ])
    |> Result.get_ok
  in
  check int "all canonical bindings" 2 (List.length bindings);
  let first = List.hd bindings in
  check string "sorted by channel id" "a-channel" first.channel_id;
  check string "preserves keeper name" "arya" first.keeper_name

let test_rejects_malformed_binding_rows () =
  let expect_error label json =
    match Store.normalize_bindings_json json with
    | Ok _ -> fail label
    | Error _ -> ()
  in
  expect_error "blank channel id was discarded"
    (`Assoc [ "", `String "luna" ]);
  expect_error "non-string keeper was discarded"
    (`Assoc [ "channel-1", `Int 1 ]);
  expect_error "blank keeper was discarded"
    (`Assoc [ "channel-1", `String " " ]);
  expect_error "non-canonical channel id was normalized"
    (`Assoc [ " channel-1", `String "luna" ]);
  expect_error "duplicate channel id was accepted"
    (`Assoc
      [ "channel-1", `String "luna"
      ; "channel-1", `String "sangsu"
      ])

let test_save_and_read_bindings_round_trip () =
  with_temp_dir @@ fun dir ->
  let store = store_for_dir dir ~guild_id_field:Store.Omit in
  Store.save_bindings store
    [
      ({ channel_id = "z-channel"; keeper_name = "luna" } : Store.binding);
      ({ channel_id = "a-channel"; keeper_name = "arya" } : Store.binding);
    ];
  let bindings = Store.read_bindings store in
  check int "two bindings" 2 (List.length bindings);
  let first = List.hd bindings in
  check string "read sorted channel" "a-channel" first.channel_id;
  check string "read sorted keeper" "arya" first.keeper_name

let test_read_bindings_result_missing_store_is_empty () =
  with_temp_dir @@ fun dir ->
  let store = store_for_dir dir ~guild_id_field:Store.Omit in
  match Store.read_bindings_result store with
  | Ok bindings -> check int "missing store means no bindings" 0 (List.length bindings)
  | Error error -> fail (Store.binding_store_error_to_string error)

let test_read_bindings_result_reports_invalid_json () =
  with_temp_dir @@ fun dir ->
  let store = store_for_dir dir ~guild_id_field:Store.Omit in
  let binding_path = Filename.concat dir "bindings.json" in
  let oc = open_out_bin binding_path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc "{not-json");
  match Store.read_bindings_result store with
  | Ok _ -> fail "expected invalid binding store to return Error"
  | Error error ->
    let err = Store.binding_store_error_to_string error in
    check bool "reports invalid JSON" true
      (String.length err > 0 && String.contains err ':')

let test_audit_failure_rolls_back_binding_mutation () =
  with_temp_dir @@ fun dir ->
  let binding_path = Filename.concat dir "bindings.json" in
  let store =
    Store.create
      ~binding_store_path:(fun () -> binding_path)
      ~binding_store_read_path:(fun () -> binding_path)
      ~binding_audit_path:(fun () -> dir)
      ~binding_audit_read_path:(fun () -> dir)
      ~guild_id_field:Store.Omit
  in
  let original =
    [ ({ channel_id = "channel-1"; keeper_name = "luna" } : Store.binding) ]
  in
  Store.save_bindings store original;
  let result =
    Store.mutate_bindings store ~decide:(fun _ ->
      Ok
        ( [ ({ channel_id = "channel-2"; keeper_name = "sangsu" }
            : Store.binding) ]
        , sample_event ~action:"bind" ()
        , () ))
  in
  (match result with
   | Ok () -> fail "audit directory unexpectedly accepted an append"
   | Error _ -> ());
  match Store.read_bindings_result store with
  | Error error -> fail (Store.binding_store_error_to_string error)
  | Ok bindings ->
    check (list string) "original binding restored after audit failure"
      [ "channel-1:luna" ]
      (List.map
         (fun (binding : Store.binding) ->
           binding.channel_id ^ ":" ^ binding.keeper_name)
         bindings)

let test_failed_mutation_cannot_erase_concurrent_success () =
  with_temp_dir @@ fun dir ->
  let binding_path = Filename.concat dir "bindings.json" in
  let audit_path = Filename.concat dir "binding_audit.jsonl" in
  let coordination_mu = Stdlib.Mutex.create () in
  let coordination = Stdlib.Condition.create () in
  let audit_calls = ref 0 in
  let first_audit_waiting = ref false in
  let second_mutation_started = ref false in
  let release_first_audit = ref false in
  let binding_audit_path () =
    Stdlib.Mutex.lock coordination_mu;
    Fun.protect
      ~finally:(fun () -> Stdlib.Mutex.unlock coordination_mu)
      (fun () ->
        incr audit_calls;
        if !audit_calls = 1 then (
          first_audit_waiting := true;
          Stdlib.Condition.broadcast coordination;
          while not !release_first_audit do
            Stdlib.Condition.wait coordination coordination_mu
          done;
          dir
        ) else audit_path)
  in
  let store =
    Store.create
      ~binding_store_path:(fun () -> binding_path)
      ~binding_store_read_path:(fun () -> binding_path)
      ~binding_audit_path
      ~binding_audit_read_path:(fun () -> audit_path)
      ~guild_id_field:Store.Omit
  in
  Store.save_bindings store
    [ ({ channel_id = "original"; keeper_name = "luna" } : Store.binding) ];
  let bind channel_id keeper_name =
    Store.mutate_bindings store ~decide:(fun bindings ->
      let updated =
        ({ channel_id; keeper_name } : Store.binding)
        :: List.filter
             (fun (binding : Store.binding) ->
               not (String.equal binding.channel_id channel_id))
             bindings
      in
      Ok (updated, sample_event ~action:"bind" (), ()))
  in
  let failed = Domain.spawn (fun () -> bind "failed" "sangsu") in
  Stdlib.Mutex.lock coordination_mu;
  while not !first_audit_waiting do
    Stdlib.Condition.wait coordination coordination_mu
  done;
  Stdlib.Mutex.unlock coordination_mu;
  let succeeded =
    Domain.spawn (fun () ->
      Stdlib.Mutex.lock coordination_mu;
      second_mutation_started := true;
      Stdlib.Condition.broadcast coordination;
      Stdlib.Mutex.unlock coordination_mu;
      bind "committed" "arya")
  in
  Stdlib.Mutex.lock coordination_mu;
  while not !second_mutation_started do
    Stdlib.Condition.wait coordination coordination_mu
  done;
  release_first_audit := true;
  Stdlib.Condition.broadcast coordination;
  Stdlib.Mutex.unlock coordination_mu;
  (match Domain.join failed with
   | Ok () -> fail "first mutation unexpectedly committed"
   | Error _ -> ());
  (match Domain.join succeeded with
   | Error error -> fail (Store.mutation_error_to_string error)
   | Ok () -> ());
  match Store.read_bindings_result store with
  | Error error -> fail (Store.binding_store_error_to_string error)
  | Ok bindings ->
    check (list string)
      "failed rollback preserves the later serialized commit"
      [ "committed:arya"; "original:luna" ]
      (bindings
       |> List.sort (fun (a : Store.binding) (b : Store.binding) ->
            String.compare a.channel_id b.channel_id)
       |> List.map (fun (binding : Store.binding) ->
            binding.channel_id ^ ":" ^ binding.keeper_name))

let test_audit_guild_id_policy () =
  with_temp_dir @@ fun dir ->
  let omit = store_for_dir dir ~guild_id_field:Store.Omit in
  let empty = store_for_dir dir ~guild_id_field:Store.Include_empty in
  let value = store_for_dir dir ~guild_id_field:Store.Include_event_value in
  let event = sample_event ~guild_id:"guild-1" ~action:"bind" () in
  check bool "omits guild_id"
    true
    (Store.audit_event_json omit event |> U.member "guild_id" = `Null);
  check string "keeps empty sidecar guild_id" ""
    (Store.audit_event_json empty event |> U.member "guild_id" |> U.to_string);
  check string "keeps discord guild_id" "guild-1"
    (Store.audit_event_json value event |> U.member "guild_id" |> U.to_string)

let test_append_and_read_recent_audit () =
  with_temp_dir @@ fun dir ->
  let store = store_for_dir dir ~guild_id_field:Store.Include_empty in
  Store.append_audit_event store (sample_event ~action:"bind" ());
  Store.append_audit_event store (sample_event ~action:"rebind" ());
  Store.append_audit_event store (sample_event ~action:"unbind" ());
  let recent = Store.read_recent_audit store ~limit:2 in
  check int "limit applied" 2 (List.length recent);
  check string "newest first" "unbind"
    (List.hd recent |> U.member "action" |> U.to_string);
  check string "second newest" "rebind"
    (List.nth recent 1 |> U.member "action" |> U.to_string)

let () =
  run "channel_gate_binding_store"
    [
      ( "bindings",
        [
          test_case "normalizes binding JSON" `Quick test_normalizes_bindings_json;
          test_case "rejects malformed binding rows" `Quick
            test_rejects_malformed_binding_rows;
          test_case "saves and reads bindings" `Quick
            test_save_and_read_bindings_round_trip;
          test_case "missing binding store is empty" `Quick
            test_read_bindings_result_missing_store_is_empty;
          test_case "invalid binding store is an error" `Quick
            test_read_bindings_result_reports_invalid_json;
          test_case "audit failure rolls back mutation" `Quick
            test_audit_failure_rolls_back_binding_mutation;
          test_case "failed rollback preserves concurrent success" `Quick
            test_failed_mutation_cannot_erase_concurrent_success;
        ] );
      ( "audit",
        [
          test_case "preserves guild_id policy" `Quick test_audit_guild_id_policy;
          test_case "reads recent audit newest first" `Quick
            test_append_and_read_recent_audit;
        ] );
    ]
