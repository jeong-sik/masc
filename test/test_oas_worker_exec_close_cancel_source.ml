(* Regression guard for #11929/#10395: OAS worker cleanup must not
   swallow Eio cancellation if Agent.close raises while handling another
   execution exception. *)

let read_file path =
  let ic = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () -> In_channel.input_all ic)

let contains haystack needle =
  let n = String.length needle in
  let h = String.length haystack in
  let rec scan i =
    if i + n > h then false
    else if String.sub haystack i n = needle then true
    else scan (i + 1)
  in
  scan 0

let assert_contains ~label haystack needle =
  if not (contains haystack needle) then
    failwith
      (Printf.sprintf "[%s] expected source to contain %S" label needle)

let assert_order ~label haystack first second =
  let position needle =
    let n = String.length needle in
    let h = String.length haystack in
    let rec scan i =
      if i + n > h then None
      else if String.sub haystack i n = needle then Some i
      else scan (i + 1)
    in
    scan 0
  in
  match position first, position second with
  | Some a, Some b when a < b -> ()
  | _ ->
      failwith
        (Printf.sprintf
           "[%s] expected %S to appear before %S in oas_worker_exec.ml"
           label first second)

let () =
  let parent p = Filename.dirname p in
  let exe = Sys.executable_name in
  let project_root = parent (parent (parent (parent exe))) in
  let candidates =
    [
      Filename.concat project_root "lib/oas_worker_exec.ml";
      "lib/oas_worker_exec.ml";
      "../lib/oas_worker_exec.ml";
    ]
  in
  let src =
    match List.find_opt Sys.file_exists candidates with
    | Some path -> read_file path
    | None ->
        failwith
          (Printf.sprintf "no oas_worker_exec.ml source path resolved (cwd=%s, exe=%s)"
             (Sys.getcwd ()) exe)
  in
  let cancel_guard = "Eio.Cancel.Cancelled _ as e ->" in
  let cancel_reraise = "if propagate_cancel then raise e" in
  let close_warning = "agent close failed during cleanup" in
  assert_contains ~label:"close cleanup cancel guard block" src
    "let close_agent_for_cleanup ?(propagate_cancel = true) ~config agent =";
  assert_contains ~label:"cleanup cancel guard" src cancel_guard;
  assert_contains ~label:"cleanup cancel re-raise" src cancel_reraise;
  assert_contains ~label:"cleanup warning anchor" src close_warning;
  assert_order ~label:"cancel guard before cleanup warning" src cancel_guard
    close_warning;
  assert_order ~label:"cancel guard before conditional re-raise" src cancel_guard
    cancel_reraise;
  print_endline "test_oas_worker_exec_close_cancel_source: OK"
