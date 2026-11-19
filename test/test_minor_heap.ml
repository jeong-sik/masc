open Alcotest

let words () = (Gc.get ()).Gc.minor_heap_size

(* Run in a child process so each case chooses its own OCAMLRUNPARAM. The
   main domain applies [Tuned] first, so every domain after it would show an
   inherited size if the runtime or [Minor_heap] passed one on. *)
let probe () =
  let main_before = words () in
  Minor_heap.apply Minor_heap.Tuned;
  let main_after = words () in
  Minor_heap.apply Minor_heap.Tuned;
  let main_again = words () in
  let started policy =
    Eio_main.run (fun env ->
      Eio.Domain_manager.run (Minor_heap.domain_mgr policy (Eio.Stdenv.domain_mgr env)) words)
  in
  let default_domain = started Minor_heap.Runtime_default in
  let tuned_domain = started Minor_heap.Tuned in
  Printf.printf "%d %d %d %d %d\n%!" main_before main_after main_again default_domain tuned_domain
;;

type sample =
  { main_before : int
  ; main_after : int
  ; main_again : int
  ; default_domain : int
  ; tuned_domain : int
  }

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
  (match status with
   | Unix.WEXITED 0 -> ()
   | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ ->
     fail "minor heap probe failed");
  Scanf.sscanf text "%d %d %d %d %d"
    (fun main_before main_after main_again default_domain tuned_domain ->
      { main_before; main_after; main_again; default_domain; tuned_domain })
;;

let test_operator_configuration setting () =
  let s = run_probe (Some setting) in
  check int "Tuned leaves the main domain on the runtime heap" s.main_before s.main_after;
  check int "a second apply changes nothing" s.main_after s.main_again;
  check int "a Runtime_default domain keeps the runtime heap" s.main_before s.default_domain;
  check int "a Tuned domain keeps the runtime heap" s.main_before s.tuned_domain
;;

let test_without_operator_configuration () =
  let s = run_probe None in
  check int "Tuned gives the main domain 4M words" (4 * 1024 * 1024) s.main_after;
  check int "a second apply changes nothing" s.main_after s.main_again;
  (* The main domain was tuned before this domain started. *)
  check int "a Runtime_default domain starts on the runtime heap, not the caller's"
    s.main_before s.default_domain;
  check int "a Tuned domain applies 4M words when it starts" (4 * 1024 * 1024) s.tuned_domain
;;

let () =
  if Array.length Sys.argv = 2 && Sys.argv.(1) = "--minor-heap-probe"
  then probe ()
  else run "minor heap chosen where a domain starts" ["domains", [
    test_case "runtime size instruction is authoritative" `Quick
      (test_operator_configuration "s=128k");
    test_case "other runtime instructions remain authoritative" `Quick
      (test_operator_configuration "b=1");
    test_case "explicit empty runtime configuration remains authoritative" `Quick
      (test_operator_configuration "");
    test_case "each domain collects on the heap its starter named" `Quick
      test_without_operator_configuration]]
