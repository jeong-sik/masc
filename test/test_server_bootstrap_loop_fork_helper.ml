open Alcotest

(** Source-level ratchet for server_bootstrap_loops fiber spawning.

    The module used to repeat raw [Eio.Fiber.fork] + cancellation-safe
    exception handling at each bootstrap/background loop site. The helper keeps
    cancellation propagation and crash logging in one place while preserving
    loop-specific iteration error handling. *)

let read_file path =
  match In_channel.with_open_text path In_channel.input_all with
  | exception _ -> ""
  | content -> content
;;

let count_substring ~haystack ~needle =
  let rec loop i acc =
    let next = String.index_from_opt haystack i needle.[0] in
    match next with
    | None -> acc
    | Some j ->
      let len = String.length needle in
      if j + len <= String.length haystack
         && String.sub haystack j len = needle
      then loop (j + len) (acc + 1)
      else loop (j + 1) acc
  in
  loop 0 0
;;

let test_raw_fork_is_owned_by_helper () =
  let content = read_file "lib/server/server_bootstrap_loops_fiber.ml" in
  check int
    "only fork_logged_fiber owns direct Eio.Fiber.fork in server_bootstrap_loops_fiber"
    1
    (count_substring ~haystack:content ~needle:"Eio.Fiber.fork ~sw (fun () ->")
;;

let test_bootstrap_sites_use_logged_helper () =
  let content = read_file "lib/server/server_bootstrap_loops.ml" in
  check bool
    "bootstrap/background fibers route through fork_logged_fiber"
    true
    (count_substring ~haystack:content ~needle:"fork_logged_fiber" >= 2)
;;

(* The sibling ratchet [test_raw_fork_is_owned_by_helper] only constrains
   server_bootstrap_loops_fiber.ml. The chat-adapter (Discord/Slack) sites in
   server_bootstrap_loops.ml used raw [Eio.Fiber.fork ~sw] directly, escaping
   that ratchet: a non-Cancelled exception from an adapter loop would fail the
   shared switch and cancel sibling fibers. Close the gap by asserting the
   loops module spawns no raw fork either; every site routes through
   [fork_logged_fiber]. *)
let test_loops_has_no_raw_fork () =
  let content = read_file "lib/server/server_bootstrap_loops.ml" in
  check int
    "no raw Eio.Fiber.fork in server_bootstrap_loops; sites route through \
     fork_logged_fiber"
    0
    (count_substring ~haystack:content ~needle:"Eio.Fiber.fork ~sw (fun () ->")
;;

let test_crash_log_names_remain_specific () =
  let content = read_file "lib/server/server_bootstrap_loops.ml" in
  List.iter
    (fun needle ->
       check bool
         (Printf.sprintf "keeps crash log surface: %s" needle)
         true
         (count_substring ~haystack:content ~needle >= 1))
    [ "subsystem %s crashed: %s"
    ; "keeper lifecycle listener"
    ]
;;

let () =
  run
    "server_bootstrap_loops fork helper"
    [ ( "fork-helper-ratchet"
      , [ test_case "raw-fork-owned-by-helper" `Quick test_raw_fork_is_owned_by_helper
        ; test_case "bootstrap-sites-use-helper" `Quick
            test_bootstrap_sites_use_logged_helper
        ; test_case "loops-has-no-raw-fork" `Quick test_loops_has_no_raw_fork
        ; test_case "crash-log-names-remain-specific" `Quick
            test_crash_log_names_remain_specific
        ] )
    ]
;;
