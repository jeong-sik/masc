let read_file path =
  let ic = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () -> In_channel.input_all ic)

let contains haystack needle =
  let n = String.length needle in
  let h = String.length haystack in
  let rec loop i =
    if i + n > h then false
    else if String.sub haystack i n = needle then true
    else loop (i + 1)
  in
  loop 0

let assert_contains ~label src needle =
  if not (contains src needle) then
    failwith (Printf.sprintf "%s: expected source to contain %S" label needle)

let assert_not_contains ~label src needle =
  if contains src needle then
    failwith
      (Printf.sprintf "%s: source must not contain %S" label needle)

let source_path () =
  let parent p = Filename.dirname p in
  let exe = Sys.executable_name in
  let project_root = parent (parent (parent (parent exe))) in
  let candidates =
    [
      Filename.concat project_root "lib/keeper/keeper_unified_turn.ml";
      "lib/keeper/keeper_unified_turn.ml";
      "../lib/keeper/keeper_unified_turn.ml";
      "../../lib/keeper/keeper_unified_turn.ml";
    ]
  in
  match List.find_opt Sys.file_exists candidates with
  | Some path -> path
  | None ->
      failwith
        (Printf.sprintf
           "keeper_unified_turn source path not found (cwd=%s exe=%s)"
           (Sys.getcwd ()) exe)

let () =
  let src = read_file (source_path ()) in
  assert_not_contains ~label:"no null fallback" src "using Null input";
  assert_contains ~label:"order violation latch" src
    "tool_event_order_violation_error";
  assert_contains ~label:"input-sensitive conservative classification" src
    "input_sensitive_mutation_tool";
  assert_contains ~label:"retry abort log" src
    "aborting retry path to avoid replaying an unpaired tool completion";
  print_endline "test_keeper_unified_tool_event_order_source: OK"
