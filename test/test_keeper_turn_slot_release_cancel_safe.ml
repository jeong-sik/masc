(* test/test_keeper_turn_slot_release_cancel_safe.ml

   Regression guard for the 2026-05-05 fleet-stuck cycle:
   [release_keeper_turn_slot] called bookkeeping functions
   (drop_autonomous_waiter / drop_holder / record_autonomous_completion)
   directly. These functions use [Eio.Mutex.use_rw ~protect:true],
   which can raise [Eio.Cancel.Cancelled] when the fiber is being
   torn down. Because the call sat in a [Fun.protect ~finally]
   block, the [Eio.Semaphore.release] line was never reached and
   the slot leaked permanently — turn_available pinned at 0 while
   the entire 14-keeper fleet skipped turns with "wait > 180s".

   The fix wraps each bookkeeping call in [safe_bookkeeping ~op],
   which catches Cancelled and lets the subsequent semaphore
   release run. This test asserts the structural pattern by
   anchored substring search, so a future refactor that removes
   the wrap fails CI before it deadlocks production.

   Why structural rather than behavioural: deterministically
   raising Cancelled inside a sub-mutex during fiber teardown
   requires a non-trivial Eio.Switch + Cancel.protect harness.
   The fix mirrors the prior-art pattern in
   [lib/keeper/keeper_unified_turn.ml] (issue #9747), so the
   regression risk we guard against is "someone removes the
   wrap", which a substring assertion catches cheaply. *)

let read_file path =
  let ic = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () -> In_channel.input_all ic)

let assert_contains ~label haystack needle =
  if not (String.length haystack >= String.length needle) then
    failwith (Printf.sprintf "[%s] file too short to contain %S" label needle);
  (* naive substring search; OCaml stdlib has no built-in *)
  let n = String.length needle in
  let h = String.length haystack in
  let rec scan i =
    if i + n > h then false
    else if String.sub haystack i n = needle then true
    else scan (i + 1)
  in
  if not (scan 0) then
    failwith
      (Printf.sprintf
         "[%s] expected source to contain %S — fix \
          regression: release_keeper_turn_slot must wrap \
          bookkeeping in safe_bookkeeping, see 2026-05-05 \
          fleet-stuck cycle"
         label needle)

let () =
  (* Resolve the source via the test exe location.  dune places
     the binary at:
       <project>/_build/default/test/<name>.exe
     so [parent x4] = the build/default subdir of the project,
     and the source is at [.../lib/keeper/keeper_turn_slot.ml].
     This is robust regardless of CWD or sandbox layout. *)
  (* exe is at <root>/_build/default/test/<name>.exe — climb 4
     levels to reach <root>, then descend into the source tree. *)
  let parent p = Filename.dirname p in
  let exe = Sys.executable_name in
  let project_root = parent (parent (parent (parent exe))) in
  let candidates =
    [ Filename.concat project_root "lib/keeper/keeper_turn_slot.ml"
    ; "lib/keeper/keeper_turn_slot.ml"
    ; "../lib/keeper/keeper_turn_slot.ml"
    ; "../../lib/keeper/keeper_turn_slot.ml"
    ]
  in
  let src =
    match List.find_opt Sys.file_exists candidates with
    | Some p -> read_file p
    | None ->
      failwith
        (Printf.sprintf
           "none of the candidate source paths resolved \
            (cwd=%s, exe=%s): %s"
           (Sys.getcwd ()) exe (String.concat ", " candidates))
  in
  (* The five labeled wraps that the fix introduces.  Ordering
     is not asserted (release order is documented as quota-
     independent) — only presence of each anchored op label. *)
  let must_contain =
    [ "drop_autonomous_waiter wrap",
      {|safe_bookkeeping ~op:"drop_autonomous_waiter"|}
    ; "drop_holder turn wrap",
      {|safe_bookkeeping ~op:"drop_holder turn"|}
    ; "record_autonomous_completion wrap",
      {|safe_bookkeeping ~op:"record_autonomous_completion"|}
    ; "drop_holder autonomous wrap",
      {|safe_bookkeeping ~op:"drop_holder autonomous"|}
    ; "drop_holder reactive wrap",
      {|safe_bookkeeping ~op:"drop_holder reactive"|}
    ]
  in
  List.iter
    (fun (label, needle) -> assert_contains ~label src needle)
    must_contain;
  (* The helper itself must catch Cancelled — assert the catch
     arm exists so a future refactor can't silently widen
     [safe_bookkeeping] to swallow only generic [exn]. *)
  assert_contains
    ~label:"safe_bookkeeping catches Cancelled"
    src
    "Eio.Cancel.Cancelled _ ->";
  (* All three semaphore releases must remain reachable
     (turn / autonomous / reactive). *)
  let count_substring ~needle s =
    let n = String.length needle in
    let h = String.length s in
    let rec loop i acc =
      if i + n > h then acc
      else if String.sub s i n = needle then loop (i + 1) (acc + 1)
      else loop (i + 1) acc
    in
    loop 0 0
  in
  let releases = count_substring ~needle:"Eio.Semaphore.release" src in
  if releases < 3 then
    failwith
      (Printf.sprintf
         "expected ≥3 Eio.Semaphore.release sites \
          (turn / autonomous / reactive); found %d"
         releases);
  print_endline "test_keeper_turn_slot_release_cancel_safe: OK"
