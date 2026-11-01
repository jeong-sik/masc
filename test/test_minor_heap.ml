open Alcotest

let sample () =
  let before = (Gc.get ()).Gc.minor_heap_size in
  Minor_heap.tune ();
  let after = (Gc.get ()).Gc.minor_heap_size in
  Minor_heap.tune ();
  before, after, (Gc.get ()).Gc.minor_heap_size
;;

let probe () =
  let before, after, again = sample () in
  let worker = Domain.spawn sample |> Domain.join in
  let worker_before, worker_after, worker_again = worker in
  Printf.printf "%d %d %d %d %d %d\n%!"
    before after again worker_before worker_after worker_again
;;

let run_probe setting =
  let inherited = Unix.environment () |> Array.to_list
    |> List.filter (fun entry -> not (String.starts_with ~prefix:"OCAMLRUNPARAM=" entry)) in
  let env = match setting with
    | None -> inherited
    | Some value -> ("OCAMLRUNPARAM=" ^ value) :: inherited in
  let read_fd, write_fd = Unix.pipe ~cloexec:true () in
  let pid = Unix.create_process_env Sys.executable_name
    [| Sys.executable_name; "--minor-heap-probe" |] (Array.of_list env)
    Unix.stdin write_fd Unix.stderr in
  Unix.close write_fd;
  let channel = Unix.in_channel_of_descr read_fd in
  let text = Fun.protect ~finally:(fun () -> close_in_noerr channel)
    (fun () -> In_channel.input_all channel) in
  let _, status = Unix.waitpid [] pid in
  (match status with Unix.WEXITED 0 -> () | _ -> fail "minor heap probe failed");
  Scanf.sscanf text "%d %d %d %d %d %d"
    (fun before after again worker_before worker_after worker_again ->
      (before, after, again), (worker_before, worker_after, worker_again))
;;

let test_operator_configuration setting () =
  let main, worker = run_probe (Some setting) in
  List.iter (fun (label, (before, after, again)) ->
    check int (label ^ " preserves the runtime heap") before after;
    check int (label ^ " remains unchanged on another job") after again)
    ["main", main; "pool domain", worker]
;;

let test_default_policy () =
  let main, worker = run_probe None in
  List.iter (fun (label, (before, after, again)) ->
    check bool (label ^ " does not shrink its heap") true (after >= before);
    check int (label ^ " is idempotent") after again)
    ["main", main; "pool domain", worker];
  let _, main_after, _ = main and _, worker_after, _ = worker in
  check int "both domains use the shared default" main_after worker_after
;;

let () =
  if Array.length Sys.argv = 2 && Sys.argv.(1) = "--minor-heap-probe"
  then probe ()
  else run "minor heap operator policy" ["domains", [
    test_case "runtime size instruction is authoritative" `Quick
      (test_operator_configuration "s=128k");
    test_case "other runtime instructions remain authoritative" `Quick
      (test_operator_configuration "b=1");
    test_case "explicit empty runtime configuration remains authoritative" `Quick
      (test_operator_configuration "");
    test_case "absent runtime configuration uses the shared default" `Quick
      test_default_policy]]
