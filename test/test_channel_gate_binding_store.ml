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
          ("z-channel", `String " luna ");
          ("", `String "ignored");
          ("bad-channel", `Int 1);
          ("a-channel", `String " arya ");
        ])
  in
  check int "valid bindings only" 2 (List.length bindings);
  let first = List.hd bindings in
  check string "sorted by channel id" "a-channel" first.channel_id;
  check string "trims keeper name" "arya" first.keeper_name

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
  | Error err -> fail err

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
  | Error err ->
    check bool "reports invalid JSON" true
      (String.length err > 0 && String.contains err ':')

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
  Eio_main.run @@ fun _env ->
  run "channel_gate_binding_store"
    [
      ( "bindings",
        [
          test_case "normalizes binding JSON" `Quick test_normalizes_bindings_json;
          test_case "saves and reads bindings" `Quick
            test_save_and_read_bindings_round_trip;
          test_case "missing binding store is empty" `Quick
            test_read_bindings_result_missing_store_is_empty;
          test_case "invalid binding store is an error" `Quick
            test_read_bindings_result_reports_invalid_json;
        ] );
      ( "audit",
        [
          test_case "preserves guild_id policy" `Quick test_audit_guild_id_policy;
          test_case "reads recent audit newest first" `Quick
            test_append_and_read_recent_audit;
        ] );
    ]
