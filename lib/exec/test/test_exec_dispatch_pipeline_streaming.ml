let lit s = Masc_exec.Shell_ir.Lit (s, Masc_exec.Shell_ir.default_meta)

let fail msg = raise (Failure msg)

let bin s =
  match Masc_exec.Exec_program.of_string s with
  | Ok bin -> bin
  | Error (`Unknown name) -> fail ("unknown exec program: " ^ name)

let simple executable args =
  let open Masc_exec.Shell_ir in
  Simple
    { bin = bin executable
    ; args = List.map lit args
    ; env = []
    ; cwd = None
    ; redirects = []
    ; sandbox = Masc_exec.Sandbox_target.host ()
    }

let test_host_pipeline_callback_is_live () =
  Eio_main.run @@ fun env ->
  Process_eio.init
    ~cwd_default:(Eio.Stdenv.cwd env)
    ~proc_mgr:(Eio.Stdenv.process_mgr env)
    ~clock:(Eio.Stdenv.clock env);
  (* NDT-OK: this regression asserts live callback wall-clock ordering. *)
  let start = Unix.gettimeofday () in
  let first_stdout_at = ref None in
  let stdout_chunks = ref [] in
  let on_output_chunk = function
    | `Stdout chunk ->
        if Option.is_none !first_stdout_at then
          (* NDT-OK: record callback arrival time relative to process start. *)
          first_stdout_at := Some (Unix.gettimeofday () -. start);
        stdout_chunks := chunk :: !stdout_chunks
    | `Stderr _ -> ()
  in
  let ir =
    Masc_exec.Shell_ir.Pipeline
      [ simple "printf" [ "input" ]
      ; simple "sh"
          [ "-c"; "cat >/dev/null; printf first; sleep 0.30; printf second" ]
      ]
  in
  let result =
    Masc_exec.Exec_dispatch.dispatch ~on_output_chunk ir
  in
  (* NDT-OK: compare process completion time to first callback arrival. *)
  let elapsed = Unix.gettimeofday () -. start in
  assert (result.status = Unix.WEXITED 0);
  assert (result.stdout = "firstsecond");
  assert (result.stderr = "");
  assert (String.concat "" (List.rev !stdout_chunks) = "firstsecond");
  match !first_stdout_at with
  | None -> fail "expected live stdout callback"
  | Some t ->
      if not (t < elapsed -. 0.12) then
        fail
          (Printf.sprintf
             "expected first stdout callback before process completion \
              (first=%.3fs elapsed=%.3fs)"
             t elapsed)

let () =
  test_host_pipeline_callback_is_live ();
  print_endline "exec_dispatch_pipeline_streaming: ok"
