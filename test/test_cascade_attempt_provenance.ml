open Alcotest

module KT = Masc_mcp.Keeper_types
module Registry = Masc_mcp.Keeper_registry

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then (
      Array.iter (fun name -> rm_rf (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path)
    else
      Unix.unlink path

let temp_base_path label =
  let base =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-test-%s-%d-%06x" label (Unix.getpid ()) (Random.bits ()))
  in
  if Sys.file_exists base then rm_rf base;
  Unix.mkdir base 0o755;
  base

let make_meta name =
  let json =
    `Assoc
      [ "name", `String name
      ; "agent_name", `String ("agent-" ^ name)
      ; "trace_id", `String ("trace-test-" ^ name)
      ; "goal", `String "test goal"
      ]
  in
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok meta -> meta
  | Error err -> fail ("make_meta failed: " ^ err)

let outcome_to_string = function
  | `Success -> "success"
  | `Failure message -> "failure:" ^ message

let test_record_cascade_attempt_round_trips_from_meta () =
  let base_path = temp_base_path "cascade-attempt-provenance" in
  Fun.protect
    ~finally:(fun () ->
      Registry.clear ();
      rm_rf base_path)
    (fun () ->
      Registry.clear ();
      let config = Masc_mcp.Coord.default_config base_path in
      ignore (Masc_mcp.Coord.init config ~agent_name:(Some "cascade-attempt-test"));
      let keeper_name = "provenance-keeper" in
      (match KT.write_meta ~force:true config (make_meta keeper_name) with
       | Ok () -> ()
       | Error err -> fail ("initial write_meta failed: " ^ err));
      let expected : KT.cascade_attempt_record =
        { provider_id = "runpod_mtp"
        ; http_status = Some 502
        ; outcome = `Failure "GGML_ASSERT(logits!=nullptr)"
        ; timestamp = 1_768_600_000.25
        }
      in
      Masc_mcp.Keeper_registry_cascade_attempt.record
        ~base_path:config.base_path
        ~keeper_name
        expected;
      match KT.read_meta config keeper_name with
      | Error err -> fail ("read_meta failed: " ^ err)
      | Ok None -> fail "keeper meta missing after cascade attempt write"
      | Ok (Some meta) ->
        (match meta.runtime.last_cascade_attempt with
         | None -> fail "last_cascade_attempt missing"
         | Some actual ->
           check string "provider_id" expected.provider_id actual.provider_id;
           check (option int) "http_status" expected.http_status actual.http_status;
           check string
             "outcome"
             (outcome_to_string expected.outcome)
             (outcome_to_string actual.outcome);
           check (float 0.000001) "timestamp" expected.timestamp actual.timestamp))

let () =
  run
    "cascade_attempt_provenance"
    [ ( "keeper-meta"
      , [ test_case
            "record_cascade_attempt persists all fields"
            `Quick
            test_record_cascade_attempt_round_trips_from_meta
        ] )
    ]
