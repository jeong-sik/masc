(* A delegated stage answers through the caller, not a process.

   RFC tools-as-shell-commands PR-1a: [Sandbox_target.Delegated] routes
   a stage's execution to an injected [caller] closure with the same
   shape the guest/SSH runners already use. These tests lock the
   round trip — argv travels in, a process-shaped answer travels back —
   and that a file redirect on a delegated stage is refused rather than
   opened on this host. *)

open Masc_exec

(* Every call is recorded; the answer is a fixed status plus the argv
   joined back together, so each test can assert on both sides. *)
let recording_caller ?(status = Unix.WEXITED 0) ?(prefix = "") () =
  let calls = ref [] in
  let runner :
      Sandbox_target.runner =
    fun ~on_stdout_chunk ~on_stderr_chunk:_ ~stdin_content:_ ~argv ~env:_ ~cwd:_ ->
      calls := argv :: !calls;
      (match on_stdout_chunk with
       | Some emit -> emit (String.concat " " argv ^ "\n")
       | None -> ());
      Sandbox_target.Ran
        { status; stdout = prefix ^ String.concat " " argv; stderr = "" }
  in
  (runner, calls)

let delegated_simple ~(caller : Sandbox_target.runner) ~argv =
  let bin = match argv with [] -> "masc" | bin :: _ -> bin in
  let open Shell_ir in
  { bin =
      (match Exec_program.of_string bin with
       | Ok program -> program
       | Error (`Unknown s) -> failwith s)
  ; args = List.tl argv |> List.map (fun a -> Lit (a, default_meta))
  ; env = []
  ; cwd = None
  ; redirects = []
  ; sandbox = Sandbox_target.delegated ~caller ()
  }

let test_delegated_round_trip () =
  let caller, calls = recording_caller () in
  let result =
    Exec_dispatch.dispatch_simple
      (delegated_simple ~caller ~argv:[ "board"; "post"; "get"; "p-1" ])
  in
  assert (result.status = Unix.WEXITED 0);
  assert (!calls = [ [ "board"; "post"; "get"; "p-1" ] ])

let test_delegated_failure_is_a_status () =
  let caller, _calls = recording_caller ~status:(Unix.WEXITED 3) ~prefix:"out:" () in
  let result =
    Exec_dispatch.dispatch_simple (delegated_simple ~caller ~argv:[ "time"; "now" ])
  in
  assert (result.status = Unix.WEXITED 3);
  assert (String.trim result.stdout = "out:time now")

let test_delegated_redirect_refused () =
  (* The caller answers with text, not descriptors, so a file redirect on
     a delegated stage must be refused instead of opened on this host. *)
  let caller, _calls = recording_caller () in
  let base = delegated_simple ~caller ~argv:[ "board"; "list" ] in
  let target =
    Redirect_scope.In_command_namespace (Path_scope.classify ~raw:"out.txt" ~cwd:".")
  in
  let stage =
    { base with
      Shell_ir.redirects =
        [ Redirect_scope.File { fd = 1; target; mode = Redirect_scope.Write } ]
    }
  in
  let result = Exec_dispatch.dispatch_simple stage in
  assert (result.status = Unix.WEXITED 1);
  assert (String.length result.stdout = 0)

let test_delegated_exception_is_reported () =
  let runner :
      Sandbox_target.runner =
    fun ~on_stdout_chunk:_ ~on_stderr_chunk:_ ~stdin_content:_ ~argv:_ ~env:_ ~cwd:_ ->
      raise (Failure "caller exploded")
  in
  let result =
    Exec_dispatch.dispatch_simple (delegated_simple ~caller:runner ~argv:[ "board"; "list" ])
  in
  assert (result.status = Unix.WEXITED 1);
  assert (String.length result.stdout = 0)

let () =
  test_delegated_round_trip ();
  test_delegated_failure_is_a_status ();
  test_delegated_redirect_refused ();
  test_delegated_exception_is_reported ();
  print_endline "[test_exec_dispatch_delegated] all tests passed"
