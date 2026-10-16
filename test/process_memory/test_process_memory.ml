let resident_bytes json =
  match Yojson.Safe.Util.member "resident_bytes" json with
  | `Int value -> Int64.of_int value
  | `Intlit value -> Int64.of_string value
  | _ -> Alcotest.fail "health did not measure process RSS"

let test_health_observes_resident_allocation () =
  let read = Server_routes_http_runtime_health_helpers.process_memory_json in
  let before = read () in
  Alcotest.(check string) "health reports a measurement" "measured"
    Yojson.Safe.Util.(before |> member "status" |> to_string);
  Alcotest.(check int) "the measured process is this process" (Unix.getpid ())
    Yojson.Safe.Util.(before |> member "pid" |> to_int);
  let allocated = Bytes.make (32 * 1024 * 1024) 'x' in
  let after = read () in
  Alcotest.(check bool) "resident bytes are positive" true
    (Int64.compare (resident_bytes before) 0L > 0);
  Alcotest.(check bool) "health observes resident memory outside the old heap sample" true
    (Int64.compare (resident_bytes after) (resident_bytes before) > 0);
  (* Keep the touched allocation alive until both native measurements finish. *)
  Alcotest.(check int) "allocation remains owned" (32 * 1024 * 1024)
    (Bytes.length (Sys.opaque_identity allocated))

let () =
  Alcotest.run "process_memory"
    [ "health", [ Alcotest.test_case "current RSS observes resident allocation" `Quick
                    test_health_observes_resident_allocation ] ]
