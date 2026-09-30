open Alcotest
module Pending = Masc_tui_lane_broadcast_pending
let require = function Ok value -> value | Error detail -> fail detail
let request id = `Assoc ["instance_id",`String "instance";
  "row_ids",`List [`String "row-b";`String "row-a"];
  "broadcast",`Bool true;"request_id",`String id]
let id json = Yojson.Safe.Util.(json |> member "request_id" |> to_string)
let rec remove path =
  if Sys.is_directory path then (Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path); Unix.rmdir path)
  else Sys.remove path
let fixture test =
  let root=Filename.temp_file "tui-broadcast" ".fixture" in
  Sys.remove root; Unix.mkdir root 0o700;
  Fun.protect ~finally:(fun () -> remove root) (fun () -> test (Filename.concat root "pending.jsonl"))
let test_restart () = fixture (fun path ->
  let scope="workspace-peer" in
  (* Child process persists before a hypothetical HTTP send, then exits before
     an answer is handled. The fresh parent has no inherited pending view. *)
  (match Unix.fork () with
   | 0 -> let prepared=Pending.prepare ~credential:"credential-a" ~path ~scope (request "first-send") |> require in
       if id prepared="first-send" then exit 0 else exit 1
   | child -> let _,status=Unix.waitpid [] child in check bool "client stopped after durable admission" true (status=Unix.WEXITED 0));
  let recovered=Pending.prepare ~credential:"credential-a" ~path ~scope (request "newly-generated-after-restart") |> require in
  check string "restart retries original request" "first-send" (id recovered);
  let other=Pending.prepare ~credential:"credential-a" ~path ~scope:"other-peer" (request "other-send") |> require in
  check string "other endpoint owns another identity" "other-send" (id other);
  require (Pending.acknowledge ~credential:"credential-a" ~path ~scope ~request:recovered
    (`Assoc ["delivery",`Assoc ["status",`String "failed"]]));
  check string "failed result preserves original identity" "first-send"
    (id (require (Pending.prepare ~credential:"credential-a" ~path ~scope (request "after-failure"))));
  check bool "foreign receipt refuses retirement" true
    (Result.is_error (Pending.acknowledge ~credential:"credential-a" ~path ~scope ~request:recovered
      (`Assoc ["delivery",`Assoc ["status",`String "committed";"request_id",`String "other-send"]])));
  let delivered state=`Assoc ["delivery",`Assoc ["status",`String "committed";
    "request_id",`String "first-send";"receipt",`Assoc ["fanout_state",`String state]]] in
  require (Pending.acknowledge ~credential:"credential-a" ~path ~scope ~request:recovered (delivered "not_started"));
  require (Pending.acknowledge ~credential:"credential-a" ~path ~scope ~request:recovered (delivered "active"));
  check string "committed row during active fanout keeps restart retry identity" "first-send"
    (id (require (Pending.prepare ~credential:"credential-a" ~path ~scope (request "after-active-retry"))));
  check bool "unknown fanout state cannot consume retry identity" true
    (Result.is_error (Pending.acknowledge ~credential:"credential-a" ~path ~scope ~request:recovered (delivered "unknown")));
  let receipt=delivered "finished" in
  require (Pending.acknowledge ~credential:"credential-a" ~path ~scope ~request:recovered receipt);
  let deliberate=Pending.prepare ~credential:"credential-a" ~path ~scope (request "deliberate-next-send") |> require in
  check string "acknowledged later action has a new identity" "deliberate-next-send" (id deliberate);
  require (Pending.acknowledge ~credential:"credential-a" ~path ~scope ~request:recovered receipt);
  check string "late duplicate receipt cannot clear later send" "deliberate-next-send"
    (id (require (Pending.prepare ~credential:"credential-a" ~path ~scope (request "unused")))) )
let test_storage_refusal () = fixture (fun path ->
  let scope="workspace-peer" in
  Unix.mkdir path 0o700;
  check bool "unwritable journal refuses admission before send" true
    (Result.is_error (Pending.prepare ~credential:"credential-a" ~path ~scope (request "never-send")));
  Unix.rmdir path;
  let channel=open_out_bin path in output_string channel "{\n"; close_out channel;
  check bool "corrupt journal never replaces an uncertain old identity" true
    (Result.is_error (Pending.prepare ~credential:"credential-a" ~path ~scope (request "never-replace"))))
let test_durable_admission () = fixture (fun path ->
  let scope="workspace-deferred" in
  let prepared=require (Pending.prepare ~credential:"credential-a" ~path ~scope (request "durable-send")) in
  let receipt=`Assoc ["delivery",`Assoc ["status",`String "committed";
    "request_id",`String "durable-send";"receipt",`Assoc ["fanout_state",`String "durable_admitted"]]] in
  require (Pending.acknowledge ~credential:"credential-a" ~path ~scope ~request:prepared receipt);
  let next=require (Pending.prepare ~credential:"credential-a" ~path ~scope (request "next-durable-send")) in
  check string "ledger ownership lets a later deliberate send use its own identity"
    "next-durable-send" (id next))

let test_changed_credential_refuses_replay () = fixture (fun path ->
  let scope="same-server" in
  let original=Pending.prepare ~credential:"actor-a-token" ~path ~scope (request "original") |> require in
  check bool "new credential cannot replay or replace pending request" true
    (Result.is_error (Pending.prepare ~credential:"actor-b-token" ~path ~scope (request "replacement")));
  check string "restored original credential reconciles the same request" "original"
    (Pending.prepare ~credential:"actor-a-token" ~path ~scope (request "fresh-id") |> require |> id);
  let receipt=`Assoc ["delivery",`Assoc ["status",`String "committed";
    "request_id",`String "original";"receipt",`Assoc ["fanout_state",`String "finished"]]] in
  require (Pending.acknowledge ~credential:"actor-b-token" ~path ~scope ~request:original receipt);
  check bool "foreign acknowledgement cannot retire original operation" true
    (Result.is_error (Pending.prepare ~credential:"actor-b-token" ~path ~scope (request "replacement")));
  require (Pending.acknowledge ~credential:"actor-a-token" ~path ~scope ~request:original receipt);
  check string "new credential may start after original settlement" "new-send"
    (Pending.prepare ~credential:"actor-b-token" ~path ~scope (request "new-send") |> require |> id))
let test_legacy_credential_refuses_replay () = fixture (fun path ->
  let legacy=`Assoc ["event",`String "pending";"scope",`String "server";
    "selection",`Assoc ["instance_id",`String "instance";"row_ids",`List [`String "row-a";`String "row-b"]];
    "request_id",`String "unknown-caller"] |> Yojson.Safe.to_string in
  Out_channel.with_open_bin path (fun channel -> output_string channel (legacy ^ "\n"));
  check bool "legacy pending identity has no caller proof and must not replay" true
    (Result.is_error (Pending.prepare ~credential:"new-credential" ~path ~scope:"server" (request "fresh"))))

let () = run "Durable TUI Broadcast identity" ["recovery",[
  test_case "changed credential refuses replay" `Quick test_changed_credential_refuses_replay;
  test_case "legacy pending identity refuses replay" `Quick test_legacy_credential_refuses_replay;
  test_case "process restart and acknowledged next send" `Quick test_restart;
  test_case "storage refuses ambiguous sends" `Quick test_storage_refusal;
  test_case "durable recipient ownership acknowledges without waiting for fanout" `Quick test_durable_admission]]
