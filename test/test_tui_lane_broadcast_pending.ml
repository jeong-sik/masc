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
   | 0 -> let prepared=Pending.prepare ~path ~scope (request "first-send") |> require in
       if id prepared="first-send" then exit 0 else exit 1
   | child -> let _,status=Unix.waitpid [] child in check bool "client stopped after durable admission" true (status=Unix.WEXITED 0));
  let recovered=Pending.prepare ~path ~scope (request "newly-generated-after-restart") |> require in
  check string "restart retries original request" "first-send" (id recovered);
  let other=Pending.prepare ~path ~scope:"other-peer" (request "other-send") |> require in
  check string "other endpoint owns another identity" "other-send" (id other);
  require (Pending.acknowledge ~path ~scope ~request:recovered
    (`Assoc ["delivery",`Assoc ["status",`String "failed"]]));
  check string "failed result preserves original identity" "first-send"
    (id (require (Pending.prepare ~path ~scope (request "after-failure"))));
  check bool "foreign receipt refuses retirement" true
    (Result.is_error (Pending.acknowledge ~path ~scope ~request:recovered
      (`Assoc ["delivery",`Assoc ["status",`String "committed";"request_id",`String "other-send"]])));
  let delivered state=`Assoc ["delivery",`Assoc ["status",`String "committed";
    "request_id",`String "first-send";"receipt",`Assoc ["fanout_state",`String state]]] in
  require (Pending.acknowledge ~path ~scope ~request:recovered (delivered "not_started"));
  require (Pending.acknowledge ~path ~scope ~request:recovered (delivered "active"));
  check string "committed row during active fanout keeps restart retry identity" "first-send"
    (id (require (Pending.prepare ~path ~scope (request "after-active-retry"))));
  check bool "unknown fanout state cannot consume retry identity" true
    (Result.is_error (Pending.acknowledge ~path ~scope ~request:recovered (delivered "unknown")));
  let receipt=delivered "finished" in
  require (Pending.acknowledge ~path ~scope ~request:recovered receipt);
  let deliberate=Pending.prepare ~path ~scope (request "deliberate-next-send") |> require in
  check string "acknowledged later action has a new identity" "deliberate-next-send" (id deliberate);
  require (Pending.acknowledge ~path ~scope ~request:recovered receipt);
  check string "late duplicate receipt cannot clear later send" "deliberate-next-send"
    (id (require (Pending.prepare ~path ~scope (request "unused")))) )
let test_storage_refusal () = fixture (fun path ->
  let scope="workspace-peer" in
  Unix.mkdir path 0o700;
  check bool "unwritable journal refuses admission before send" true
    (Result.is_error (Pending.prepare ~path ~scope (request "never-send")));
  Unix.rmdir path;
  let channel=open_out_bin path in output_string channel "{\n"; close_out channel;
  check bool "corrupt journal never replaces an uncertain old identity" true
    (Result.is_error (Pending.prepare ~path ~scope (request "never-replace"))))
let () = run "Durable TUI Broadcast identity" ["recovery",[
  test_case "process restart and acknowledged next send" `Quick test_restart;
  test_case "storage refuses ambiguous sends" `Quick test_storage_refusal]]
