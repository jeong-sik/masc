open Alcotest

module Boundary = Server_dashboard_http_keeper_event_queue_operator.For_testing

let member name json = Yojson.Safe.Util.member name json
let contains text needle = Re.execp (Re.compile (Re.str needle)) text

let check_unavailable receipt =
  check bool "audit failure stays visible" false
    (member "recorded" receipt |> Yojson.Safe.Util.to_bool);
  check string "stable public failure code"
    "keeper_event_queue_audit_unavailable"
    (member "code" receipt |> Yojson.Safe.Util.to_string)

let test_success () =
  let calls = ref 0 in
  let receipt = Boundary.record_audit (fun () -> incr calls) in
  check int "one append attempt" 1 !calls;
  check bool "successful append is recorded" true
    (member "recorded" receipt |> Yojson.Safe.Util.to_bool)

let test_opaque_exception () =
  let secret = "opaque-credential-69e1204367a94795a85a979ba572bf4a" in
  let diagnostic = secret ^ String.make (64 * 1024) 'x' in
  let receipt = Boundary.record_audit (fun () -> raise (Sys_error diagnostic)) in
  check_unavailable receipt;
  let serialized = Yojson.Safe.to_string receipt in
  check bool "opaque exception payload is not projected" false
    (contains serialized secret);
  check bool "large exception payload is not projected" false
    (contains serialized diagnostic)

let test_filesystem_failure () =
  let path = Filename.temp_file "opaque-audit-credential-" "" in
  Fun.protect ~finally:(fun () -> Sys.remove path) (fun () ->
    (* A regular file cannot contain a child: this fails independently of the
       process's UID and produces a real Sys_error containing the private path. *)
    let child = Filename.concat path "audit.jsonl" in
    let receipt = Boundary.record_audit (fun () ->
      let channel = open_out_bin child in
      close_out channel) in
    check_unavailable receipt;
    check bool "filesystem path is not projected" false
      (contains (Yojson.Safe.to_string receipt) path))

let test_cancellation () =
  let cancellation = Eio.Cancel.Cancelled (Failure "audit-cancelled") in
  match Boundary.record_audit (fun () -> raise cancellation) with
  | _ -> fail "cancellation was converted to an audit receipt"
  | exception caught ->
    check bool "the original cancellation propagates" true (caught == cancellation)

let () =
  run "Keeper event queue operator audit receipt"
    [ "recording",
      [ test_case "success" `Quick test_success
      ; test_case "opaque large exception" `Quick test_opaque_exception
      ; test_case "real filesystem failure" `Quick test_filesystem_failure
      ; test_case "cancellation propagates" `Quick test_cancellation
      ]
    ]
