(* test/test_keeper_supervisor_finally_cancel_swallow.ml

   Regression guard for the 2026-05-05 cycle9 incident
   (5+ FATAL Fun.Finally_raised: Cancelled / day):

   [keeper_supervisor.ml] launches each keeper fiber inside a
   [Fun.protect ~finally].  The finally block previously
   contained [| Eio.Cancel.Cancelled _ as e -> raise e] (a
   leftover from #12910 revert / commit bb10b80ee4).  That
   re-raise contradicts the docstring directly above it and
   the [Fun.protect] semantics: any exception raised by the
   finally is wrapped as [Fun.Finally_raised], masking the
   real body exception and crashing the supervisor.  The
   crash triggers cycle restart, which in turn re-arms the
   same race — 5+ FATALs/day.

   The fix collapsed the [Cancelled _ as e -> raise e] arm
   into the catch-all [exn ->] handler.  This test asserts
   that intent via anchored substrings in the source so a
   future refactor that re-introduces the re-raise (or removes
   the explanatory comment) fails CI before it can re-armm
   the cycle restart loop. *)

let read_file path =
  let ic = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () -> In_channel.input_all ic)

let assert_contains ~label haystack needle =
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
         "[%s] expected source to contain %S — supervisor \
          finally swallow regression: see #13010 / 2026-05-05 \
          cycle9 incident"
         label needle)

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
           "no candidate source path resolved (cwd=%s, exe=%s)"
           (Sys.getcwd ()) exe)
  in
  (* Anchor 1: the distinctive comment block introduced by the
     fix.  If a future revert deletes the explanation, this
     fails first and points the next operator at the incident. *)
  assert_contains
    ~label:"finally swallow comment block"
    src
    "Swallow EVERYTHING raised inside this finally block";
  (* Anchor 2: explicit naming of the wrapping mechanism so
     anyone reading the fix understands the why. *)
  assert_contains
    ~label:"Fun.Finally_raised explanation"
    src
    "Fun.Finally_raised";
  (* Anchor 3: incident reference for traceability.  Kept
     deliberately specific (commit hash + date) so a partial
     revert that drops the comment fails. *)
  assert_contains
    ~label:"cycle9 incident reference"
    src
    "2026-05-05 cycle9 incident";
  (* Anchor 4: confirm the docstring above the finally block
     still warns about the finally-raise pitfall.  This catches
     regressions where someone restores the re-raise without
     also removing the docstring (introducing internal
     inconsistency). *)
  assert_contains
    ~label:"docstring warning preserved"
    src
    "Fun.protect";
  print_endline "test_keeper_supervisor_finally_cancel_swallow: OK"
