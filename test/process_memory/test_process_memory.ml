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
  let path = Filename.temp_file "masc-resident-memory-" ".bin" in
  let fd = Unix.openfile path [Unix.O_RDWR] 0o600 in
  Fun.protect
    ~finally:(fun () -> Unix.close fd; Unix.unlink path)
    (fun () ->
       let size = 32 * 1024 * 1024 in
       Unix.ftruncate fd size;
       let mapped =
         Unix.map_file fd Bigarray.char Bigarray.c_layout true [| size |]
         |> Bigarray.array1_of_genarray
       in
       (* A fresh mapping avoids reusing an already resident OCaml heap arena. *)
       for offset = 0 to size - 1 do
         Bigarray.Array1.set mapped offset 'x'
       done;
       let after = read () in
       Alcotest.(check bool) "resident bytes are positive" true
         (Int64.compare (resident_bytes before) 0L > 0);
       Alcotest.(check bool) "health observes resident memory outside the OCaml heap" true
         (Int64.compare (resident_bytes after) (resident_bytes before) > 0);
       Alcotest.(check int) "mapping remains owned" size
         (Bigarray.Array1.dim (Sys.opaque_identity mapped)))

let () =
  Alcotest.run "process_memory"
    [ "health", [ Alcotest.test_case "current RSS observes resident allocation" `Quick
                    test_health_observes_resident_allocation ] ]
