(* Regression guard for #11929.

   [Cascade_runner.run] must clean up a built OAS agent when the
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
         "[%s] expected Cascade_runner source to contain %S"
         label needle)

let find_substring_from haystack needle start =
  let n = String.length needle in
  let h = String.length haystack in
  let rec scan i =
    if i + n > h then None
    else if String.sub haystack i n = needle then Some i
    else scan (i + 1)
  in
  scan start

let assert_ordered_contains ~label haystack needles =
  let rec loop start = function
    | [] -> ()
    | needle :: rest -> (
        match find_substring_from haystack needle start with
        | Some idx -> loop (idx + String.length needle) rest
        | None ->
            failwith
              (Printf.sprintf
                 "[%s] expected Cascade_runner source to contain %S after offset %d"
                 label needle start))
  in
  loop 0 needles

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
             "no candidate Cascade_runner source path resolved \
              (cwd=%s, exe=%s)"
             (Sys.getcwd ()) exe)
  in
  assert_contains
    ~label:"cleanup helper exists"
    src
    "let close_agent_for_cleanup ?(propagate_cancel = true) ~config agent =";
  assert_contains
    ~label:"cleanup helper handles cleanup cancellation"
    src
    "agent close cancelled during cleanup";
  assert_contains
    ~label:"ordinary cleanup log includes worker name"
    src
    "oas_worker %s: agent close failed during cleanup: %s";
  assert_ordered_contains
    ~label:"run cancellation closes agent before re-raise"
    src
    [
      "Eio.Cancel.Cancelled";
      "close_agent_for_cleanup ~propagate_cancel:false ~config agent";
      "raise ";
    ];
  assert_ordered_contains
    ~label:"ordinary exception uses same cleanup helper"
    src
    [
      "let bt = Printexc.get_backtrace ()";
      "close_agent_for_cleanup ~config agent";
      "let detail =";
    ];
  print_endline "test_oas_worker_exec_cancel_cleanup: OK"
