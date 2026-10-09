open Alcotest
module Pending = Masc_tui_msx_checkpoint_pending
let require = function Ok value -> value | Error detail -> fail detail
let binding ~root id restore : Pending.binding =
  {operation_id=require (Keeper_operation_id.of_string id); restore; slot="quick";
   base_path=Filename.dirname root; masc_root=root}
let with_root f =
  let root = Filename.temp_file "checkpoint-intent-" "" in
  Sys.remove root;
  Unix.mkdir root 0o700;
  let rec remove path =
    if Sys.is_directory path then (
      Array.iter (fun child -> remove (Filename.concat path child)) (Sys.readdir path);
      Unix.rmdir path)
    else Sys.remove path in
  Fun.protect ~finally:(fun () -> remove root) (fun () -> f root)
let test_restart_and_exact_retirement () = with_root (fun root ->
  let restore = binding ~root "restore-before-restart" true in
  let save = binding ~root "save-before-restart" false in
  require (Pending.remember ~masc_root:root restore);
  require (Pending.remember ~masc_root:root save);
  (* The reader shares no process-local pending map with the writer. Both
     bindings remain inspectable after reconstructing all client state. *)
  let recovered = require (Pending.load ~masc_root:root) in
  check int "all unresolved operations survive restart" 2 (List.length recovered);
  check bool "the original restore identity is recovered" true (List.mem restore recovered);
  let other_base = {save with base_path=Filename.concat root "different-base"} in
  check bool "same root does not authorize rewriting the captured base" true
    (Result.is_error (Pending.remember ~masc_root:root other_base));
  check bool "captured workspace survives a caller with another base" true
    (List.mem save (require (Pending.load ~masc_root:root)));
  require (Pending.forget ~masc_root:root restore);
  check bool "verifying one operation cannot clear another" true
    (require (Pending.load ~masc_root:root) = [save]);
  with_root (fun other -> check int "another workspace has no inherited gate" 0
    (List.length (require (Pending.load ~masc_root:other)))))
let test_corruption_is_not_an_empty_gate () = with_root (fun root ->
  let restore = binding ~root "pending-restore" true in
  require (Pending.remember ~masc_root:root restore);
  let path = Filename.concat (Filename.concat (Filename.concat root "tui") "checkpoint-pending") "pending-restore.json" in
  Out_channel.with_open_text path (fun out -> output_string out "{bad json");
  check bool "unreadable binding prevents a fresh mutation admission" true
    (Result.is_error (Pending.load ~masc_root:root)))
let test_failed_intent_write_refuses_dispatch () = with_root (fun root ->
  Out_channel.with_open_text (Filename.concat root "tui") (fun out -> output_string out "not a directory");
  check bool "intent must be durable before caller dispatches" true
    (Result.is_error (Pending.remember ~masc_root:root (binding ~root "not-dispatched" true))))
let () = run "MSX durable pending checkpoint" ["intent",[
  test_case "restart preserves operation identity and workspace" `Quick test_restart_and_exact_retirement;
  test_case "corruption fails closed" `Quick test_corruption_is_not_an_empty_gate;
  test_case "failed intent persistence refuses dispatch" `Quick test_failed_intent_write_refuses_dispatch]]
