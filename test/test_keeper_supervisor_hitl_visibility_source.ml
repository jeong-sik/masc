(* Regression guard for the HITL approval visibility warning in
   [keeper_supervisor.ml].

   A keeper with a pending approval intentionally does not run a new turn. The
   operator-facing bug was that the chat appeared to stall without a supervisor
   signal explaining that the keeper was waiting for approval. The runtime
   behavior lives inside the supervisor sweep loop, so this test pins the source
   anchors that make the condition visible without needing a full supervisor
   fixture. *)

let read_file path =
  let ic = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () -> In_channel.input_all ic)
;;

let assert_contains ~label haystack needle =
  let n = String.length needle in
  let h = String.length haystack in
  let rec scan i =
    if i + n > h
    then false
    else if String.sub haystack i n = needle
    then true
    else scan (i + 1)
  in
  if not (scan 0)
  then
    failwith
      (Printf.sprintf
         "[%s] expected keeper_supervisor.ml to contain %S"
         label
         needle)
;;

let assert_before ~label haystack first second =
  let index needle =
    let re = Str.regexp_string needle in
    try Some (Str.search_forward re haystack 0) with
    | Not_found -> None
  in
  match index first, index second with
  | Some a, Some b when a < b -> ()
  | Some _, Some _ ->
    failwith
      (Printf.sprintf
         "[%s] expected %S before %S in keeper_supervisor.ml"
         label
         first
         second)
  | None, _ -> failwith (Printf.sprintf "[%s] missing %S" label first)
  | _, None -> failwith (Printf.sprintf "[%s] missing %S" label second)
;;

let () =
  let parent p = Filename.dirname p in
  let exe = Sys.executable_name in
  let project_root = parent (parent (parent (parent exe))) in
  let candidates =
    [ Filename.concat project_root "lib/keeper/keeper_supervisor.ml"
    ; "lib/keeper/keeper_supervisor.ml"
    ; "../lib/keeper/keeper_supervisor.ml"
    ]
  in
  let src =
    match List.find_opt Sys.file_exists candidates with
    | Some p -> read_file p
    | None ->
      failwith
        (Printf.sprintf
           "no keeper_supervisor.ml candidate resolved (cwd=%s, exe=%s)"
           (Sys.getcwd ())
           exe)
  in
  assert_contains
    ~label:"pending approval queue guard"
    src
    "Keeper_approval_queue.has_pending_for_keeper ~keeper_name:name";
  assert_contains
    ~label:"operator-visible warning"
    src
    "blocked on pending HITL approval; chat awaits operator decision";
  assert_contains
    ~label:"all keeper names swept"
    src
    "Keeper_meta_store.keeper_names ctx.config";
  assert_before
    ~label:"visibility before recovery decisions"
    src
    "Keeper_approval_queue.has_pending_for_keeper ~keeper_name:name"
    "Keeper_registry.all ~base_path ()";
  print_endline "test_keeper_supervisor_hitl_visibility_source: OK"
;;
