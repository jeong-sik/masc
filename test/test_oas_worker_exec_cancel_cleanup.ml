(* Regression guard for #11929.

   [Oas_worker_exec.run] must clean up a built OAS agent when the
   surrounding Eio cancellation context aborts [Agent.run]. Ordinary
   exceptions already used the cleanup path; cancellation previously
   re-raised before [Agent.close], leaving the wrapper dependent on
   lower-level switch cleanup. *)

let read_file path =
  let ic = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () -> In_channel.input_all ic)

let contains_substring haystack needle =
  let n = String.length needle in
  let h = String.length haystack in
  let rec scan i =
    if i + n > h then false
    else if String.sub haystack i n = needle then true
    else scan (i + 1)
  in
  scan 0

let assert_contains ~label haystack needle =
  if not (contains_substring haystack needle) then
    failwith
      (Printf.sprintf
         "[%s] expected Oas_worker_exec source to contain %S"
         label needle)

let () =
  let parent p = Filename.dirname p in
  let exe = Sys.executable_name in
  let project_root = parent (parent (parent (parent exe))) in
  let candidates =
    [ Filename.concat project_root "lib/oas_worker_exec.ml"
    ; "lib/oas_worker_exec.ml"
    ; "../lib/oas_worker_exec.ml"
    ; "../../lib/oas_worker_exec.ml"
    ]
  in
  let src =
    match List.find_opt Sys.file_exists candidates with
    | Some path -> read_file path
    | None ->
        failwith
          (Printf.sprintf
             "no candidate Oas_worker_exec source path resolved \
              (cwd=%s, exe=%s)"
             (Sys.getcwd ()) exe)
  in
  assert_contains
    ~label:"cleanup helper exists"
    src
    "let close_agent_for_cleanup ~config agent =";
  assert_contains
    ~label:"cleanup helper swallows cleanup cancellation"
    src
    "agent close cancelled during cleanup";
  assert_contains
    ~label:"run cancellation closes agent before re-raise"
    src
    "Eio.Cancel.Cancelled _ as exn ->\n    close_agent_for_cleanup ~config agent;\n    raise exn";
  assert_contains
    ~label:"ordinary exception uses same cleanup helper"
    src
    "let bt = Printexc.get_backtrace () in\n    close_agent_for_cleanup ~config agent";
  print_endline "test_oas_worker_exec_cancel_cleanup: OK"
