(* Dispatch is where a redirect stops being a description and becomes bytes on
   disk. Every case here runs a real command through the real IR and then reads
   the file back. *)

module E = Masc_exec

let temp_dir =
  Filename.concat (Filename.get_temp_dir_name ()) "masc-dispatch-file-redirect"
;;

let path name = Filename.concat temp_dir name

let read_file p =
  let ic = open_in_bin p in
  Fun.protect
    ~finally:(fun () -> close_in ic)
    (fun () -> really_input_string ic (in_channel_length ic))
;;

let write_file p contents =
  let oc = open_out_bin p in
  Fun.protect ~finally:(fun () -> close_out oc) (fun () -> output_string oc contents)
;;

let remove_if_present p = if Sys.file_exists p then Sys.remove p

let lit s = E.Shell_ir.Lit (s, E.Shell_ir.default_meta)

let bin name =
  match E.Exec_program.of_string name with
  | Ok bin -> bin
  | Error (`Unknown raw) -> Alcotest.failf "unknown exec program: %s" raw
;;

let target p =
  E.Redirect_scope.In_command_namespace (E.Path_scope.classify ~raw:p ~cwd:temp_dir)
;;

let host_target p =
  E.Redirect_scope.on_this_host (E.Path_scope.classify ~raw:p ~cwd:temp_dir) p

let simple ?(redirects = []) ?sandbox executable args =
  { E.Shell_ir.bin = bin executable
  ; args = List.map lit args
  ; env = []
  ; cwd = None
  ; redirects
  ; sandbox = Option.value sandbox ~default:(E.Sandbox_target.host ())
  }
;;

let with_runtime f =
  Eio_main.run @@ fun env ->
  Process_eio.init
    ~cwd_default:(Eio.Stdenv.fs env)
    ~proc_mgr:(Eio.Stdenv.process_mgr env)
    ~clock:(Eio.Stdenv.clock env);
  f ()
;;

let dispatch s = E.Exec_dispatch.dispatch (E.Shell_ir.Simple s)

let exited_zero (r : E.Exec_dispatch.dispatch_result) =
  match r.status with
  | Unix.WEXITED 0 -> true
  | _ -> false
;;

let test_stdout_lands_on_disk () =
  with_runtime (fun () ->
    let out = path "dispatch-out.txt" in
    remove_if_present out;
    let s =
      simple
        ~redirects:
          [ E.Redirect_scope.File
              { fd = 1; target = target out; mode = E.Redirect_scope.Write }
          ]
        "printf"
        [ "hello" ]
    in
    let result = dispatch s in
    Alcotest.(check bool) "the command ran" true (exited_zero result);
    Alcotest.(check string) "the bytes did not come back" "" result.stdout;
    Alcotest.(check string) "the bytes are on disk" "hello" (read_file out))
;;

let test_append_adds_to_the_file () =
  with_runtime (fun () ->
    let out = path "dispatch-append.txt" in
    write_file out "kept ";
    let s =
      simple
        ~redirects:
          [ E.Redirect_scope.File
              { fd = 1; target = target out; mode = E.Redirect_scope.Append }
          ]
        "printf"
        [ "added" ]
    in
    let _ = dispatch s in
    Alcotest.(check string) "append kept what was there" "kept added" (read_file out))
;;

(* Reading nothing is the most innocuous redirect there is, and it used to be
   refused because the discard shortcut was wired only to the write side. *)
let test_stdin_from_dev_null_runs () =
  with_runtime (fun () ->
    let s =
      simple
        ~redirects:
          [ E.Redirect_scope.File
              { fd = 0
              ; target = E.Redirect_scope.In_command_namespace (E.Path_scope.classify ~raw:"/dev/null" ~cwd:temp_dir)
              ; mode = E.Redirect_scope.Read
              }
          ]
        "cat"
        []
    in
    let result = dispatch s in
    Alcotest.(check bool) "cat ran" true (exited_zero result);
    Alcotest.(check string) "and read nothing" "" result.stdout)
;;

let test_stdin_reads_a_real_file () =
  with_runtime (fun () ->
    let input = path "dispatch-in.txt" in
    write_file input "from disk\n";
    let s =
      simple
        ~redirects:
          [ E.Redirect_scope.File
              { fd = 0; target = target input; mode = E.Redirect_scope.Read }
          ]
        "cat"
        []
    in
    let result = dispatch s in
    Alcotest.(check string) "cat read the file" "from disk\n" result.stdout)
;;

(* Commands with no file redirect must take exactly the plumbing they took
   before, so this pins the unchanged path rather than trusting it. *)
let test_discard_still_drops_without_touching_a_file () =
  with_runtime (fun () ->
    let s =
      simple
        ~redirects:
          [ E.Redirect_scope.File
              { fd = 1
              ; target = E.Redirect_scope.In_command_namespace (E.Path_scope.classify ~raw:"/dev/null" ~cwd:temp_dir)
              ; mode = E.Redirect_scope.Write
              }
          ]
        "printf"
        [ "dropped" ]
    in
    let result = dispatch s in
    Alcotest.(check bool) "the command ran" true (exited_zero result);
    Alcotest.(check string) "and its output went nowhere" "" result.stdout)
;;

let test_unopenable_target_does_not_claim_the_command_ran () =
  with_runtime (fun () ->
    let out = Filename.concat (path "no-such-directory") "out.txt" in
    let s =
      simple
        ~redirects:
          [ E.Redirect_scope.File
              { fd = 1; target = target out; mode = E.Redirect_scope.Write }
          ]
        "printf"
        [ "hello" ]
    in
    let result = dispatch s in
    Alcotest.(check bool) "it did not report success" false (exited_zero result);
    Alcotest.(check bool)
      "and it says which path"
      true
      (Astring.String.is_infix ~affix:"out.txt" result.stderr))
;;

let test_ssh_redirect_is_named_and_never_opens_host_file () =
  with_runtime (fun () ->
    let out = path "ssh-must-not-open.txt" in
    remove_if_present out;
    let runner ~on_stdout_chunk:_ ~on_stderr_chunk:_ ~stdin_content:_ ~argv:_
        ~env:_ ~cwd:_ =
      E.Sandbox_target.Ran { status = Unix.WEXITED 0; stdout = "remote"; stderr = "" }
    in
    let endpoint : E.Sandbox_target.ssh_endpoint =
      { name = "fixture"
      ; host = "fixture.invalid"
      ; user = "masc"
      ; port = 22
      ; identity_file = "/key"
      ; known_hosts_file = "/known-hosts"
      ; remote_root = "/srv/masc/playground"
      ; connect_timeout_sec = 1
      ; env_allowlist = []
      }
    in
    let sandbox = E.Sandbox_target.ssh ~endpoint ~runner () in
    let s =
      simple ~sandbox
        ~redirects:
          [ E.Redirect_scope.File
              { fd = 1; target = target out; mode = E.Redirect_scope.Write }
          ]
        "printf" [ "hello" ]
    in
    let result = dispatch s in
    Alcotest.(check bool) "command did not report success" false (exited_zero result);
    Alcotest.(check bool) "named remote redirect error" true
      (Astring.String.is_infix ~affix:"remote_ssh_redirect_unavailable" result.stderr);
    Alcotest.(check bool) "host file was not opened" false (Sys.file_exists out))
;;

(* A relative target resolves against the command's cwd. Without one, the
   child runs at the filesystem root while this process sits somewhere else,
   so the same string names two different files. *)
let test_relative_target_without_a_cwd_is_refused () =
  with_runtime (fun () ->
    let s =
      simple
        ~redirects:
          [ E.Redirect_scope.File
              { fd = 1
              ; target =
                  E.Redirect_scope.In_command_namespace
                    (E.Path_scope.classify ~raw:"relative-out.txt" ~cwd:temp_dir)
              ; mode = E.Redirect_scope.Write
              }
          ]
        "printf"
        [ "hello" ]
    in
    let result = dispatch { s with cwd = None } in
    Alcotest.(check bool) "it did not report success" false (exited_zero result);
    Alcotest.(check bool)
      "and it says a cwd is missing"
      true
      (Astring.String.is_infix ~affix:"cwd" result.stderr))
;;

let pipeline stages = E.Exec_dispatch.dispatch (E.Shell_ir.Pipeline stages)

(* A stage naming a file used to knock the whole pipeline off real process
   pipes and onto a buffered chain that runs each stage to completion in turn.
   `yes` only stops when its reader closes, so that chain never returned. This
   finishing at all is the assertion. *)
let test_a_stage_redirect_keeps_real_pipes () =
  with_runtime (fun () ->
    let out = path "pipeline-out.txt" in
    remove_if_present out;
    let result =
      pipeline
        [ E.Shell_ir.Simple (simple "yes" [ "line" ])
        ; E.Shell_ir.Simple
            (simple
               ~redirects:
                 [ E.Redirect_scope.File
                     { fd = 1; target = target out; mode = E.Redirect_scope.Write }
                 ]
               "head"
               [ "-1" ])
        ]
    in
    ignore result;
    Alcotest.(check string) "the last stage wrote the file" "line\n" (read_file out))
;;

let test_pipeline_still_pipes_without_a_redirect () =
  with_runtime (fun () ->
    let result =
      pipeline
        [ E.Shell_ir.Simple (simple "printf" [ "a\nb\nc\n" ])
        ; E.Shell_ir.Simple (simple "head" [ "-2" ])
        ]
    in
    Alcotest.(check string) "the pipe still carries bytes" "a\nb\n" result.stdout)
;;

let sequence head tail = E.Exec_dispatch.dispatch (E.Shell_ir.Sequence { head; tail })

let ok argv = E.Shell_ir.Simple (simple "true" argv)
let fails = E.Shell_ir.Simple (simple "false" [])
let says text = E.Shell_ir.Simple (simple "printf" [ text ])

(* `a && b` runs b only when a exited zero. Keepers write this today as a
   literal argv token, where no shell reads it and the second command never
   runs at all. *)
let test_and_runs_the_next_command_after_success () =
  with_runtime (fun () ->
    let result = sequence (ok []) [ E.Shell_ir.And_if, says "ran" ] in
    Alcotest.(check string) "the guarded command ran" "ran" result.stdout)
;;

let test_and_skips_the_next_command_after_failure () =
  with_runtime (fun () ->
    let result = sequence fails [ E.Shell_ir.And_if, says "ran" ] in
    Alcotest.(check string) "the guarded command did not run" "" result.stdout;
    Alcotest.(check bool) "and the failure is the outcome" false (exited_zero result))
;;

let test_or_runs_the_next_command_after_failure () =
  with_runtime (fun () ->
    let result = sequence fails [ E.Shell_ir.Or_if, says "recovered" ] in
    Alcotest.(check string) "the fallback ran" "recovered" result.stdout;
    Alcotest.(check bool) "and its success is the outcome" true (exited_zero result))
;;

(* Each guard reads whatever ran last, so a run of them goes left to right
   with no precedence of its own: `false || printf a && printf b` runs both. *)
let test_guards_read_whatever_ran_last () =
  with_runtime (fun () ->
    let result =
      sequence fails [ E.Shell_ir.Or_if, says "a"; E.Shell_ir.And_if, says "b" ]
    in
    Alcotest.(check string) "both continuations ran, in order" "ab" result.stdout)
;;

(* The fd merge joins two capture buffers after the run, so it groups by
   stream instead of by time. A real dup2 would give "err\nout\n" here. This
   pins the behaviour the schema now states, so a later move to real
   descriptors has to update both together. *)
let test_fd_merge_groups_by_stream_not_by_time () =
  with_runtime (fun () ->
    let s =
      simple
        ~redirects:
          [ E.Redirect_scope.Fd_to_fd { src = 2; dst = 1 } ]
        "sh"
        [ "-c"; "echo err >&2; sleep 0.2; echo out" ]
    in
    let result = dispatch s in
    Alcotest.(check string) "grouped by stream" "out\nerr\n" result.stdout;
    Alcotest.(check string) "and nothing is left on stderr" "" result.stderr)
;;

let docker_sandbox () =
  E.Sandbox_target.docker
    ~image:"redirect-image"
    ~runner:(fun ~on_stdout_chunk:_ ~on_stderr_chunk:_ ~stdin_content:_ ~argv:_ ~env:_ ~cwd:_ ->
      Alcotest.fail "the runner must not be reached when the target is unresolved")
    ()
;;

(* A sandboxed stage names paths as the sandbox sees them. Opening one of
   those here would hit whatever this host happens to have at that path, so
   an untranslated target is refused and the command does not run. *)
let test_sandboxed_stage_refuses_an_untranslated_target () =
  with_runtime (fun () ->
    let s =
      simple
        ~sandbox:(docker_sandbox ())
        ~redirects:
          [ E.Redirect_scope.File
              { fd = 1
              ; target = target (path "sandbox-out.txt")
              ; mode = E.Redirect_scope.Write
              }
          ]
        "printf"
        [ "hello" ]
    in
    let result = dispatch s in
    Alcotest.(check bool) "it did not report success" false (exited_zero result);
    Alcotest.(check bool)
      "and it says the path is the sandbox's"
      true
      (Astring.String.is_infix ~affix:"sandbox" result.stderr))
;;

(* Once a layer that knows the mounts has resolved it, the same stage writes
   the file, because the path now names something on this filesystem. *)
let test_sandboxed_stage_writes_a_resolved_target () =
  with_runtime (fun () ->
    let out = path "sandbox-resolved.txt" in
    remove_if_present out;
    let ran = ref false in
    let runner ~on_stdout_chunk:_ ~on_stderr_chunk:_ ~stdin_content:_ ~argv:_ ~env:_ ~cwd:_ =
      ran := true;
      E.Sandbox_target.Ran
        { status = Unix.WEXITED 0; stdout = "from the container"; stderr = "" }
    in
    let s =
      simple
        ~sandbox:(E.Sandbox_target.docker ~image:"redirect-image" ~runner ())
        ~redirects:
          [ E.Redirect_scope.File
              { fd = 1; target = host_target out; mode = E.Redirect_scope.Write }
          ]
        "printf"
        [ "hello" ]
    in
    let result = dispatch s in
    Alcotest.(check bool) "the stage was not refused" true !ran;
    Alcotest.(check string) "the bytes did not come back" "" result.stdout;
    Alcotest.(check string) "they are in the file" "from the container" (read_file out))
;;

let () =
  (try Sys.mkdir temp_dir 0o700 with Sys_error _ -> ());
  Alcotest.run
    "exec dispatch file redirect"
    [ ( "dispatch"
      , [ Alcotest.test_case
            "sandboxed_stage_refuses_an_untranslated_target"
            `Quick
            test_sandboxed_stage_refuses_an_untranslated_target
        ; Alcotest.test_case
            "sandboxed_stage_writes_a_resolved_target"
            `Quick
            test_sandboxed_stage_writes_a_resolved_target
        ; Alcotest.test_case "stdout_lands_on_disk" `Quick test_stdout_lands_on_disk
        ; Alcotest.test_case "append_adds_to_the_file" `Quick test_append_adds_to_the_file
        ; Alcotest.test_case
            "stdin_from_dev_null_runs"
            `Quick
            test_stdin_from_dev_null_runs
        ; Alcotest.test_case "stdin_reads_a_real_file" `Quick test_stdin_reads_a_real_file
        ; Alcotest.test_case
            "discard_still_drops_without_touching_a_file"
            `Quick
            test_discard_still_drops_without_touching_a_file
        ; Alcotest.test_case
            "fd_merge_groups_by_stream_not_by_time"
            `Quick
            test_fd_merge_groups_by_stream_not_by_time
        ; Alcotest.test_case
            "and_runs_the_next_command_after_success"
            `Quick
            test_and_runs_the_next_command_after_success
        ; Alcotest.test_case
            "and_skips_the_next_command_after_failure"
            `Quick
            test_and_skips_the_next_command_after_failure
        ; Alcotest.test_case
            "or_runs_the_next_command_after_failure"
            `Quick
            test_or_runs_the_next_command_after_failure
        ; Alcotest.test_case
            "guards_read_whatever_ran_last"
            `Quick
            test_guards_read_whatever_ran_last
        ; Alcotest.test_case
            "a_stage_redirect_keeps_real_pipes"
            `Quick
            test_a_stage_redirect_keeps_real_pipes
        ; Alcotest.test_case
            "pipeline_still_pipes_without_a_redirect"
            `Quick
            test_pipeline_still_pipes_without_a_redirect
        ; Alcotest.test_case
            "relative_target_without_a_cwd_is_refused"
            `Quick
            test_relative_target_without_a_cwd_is_refused
        ; Alcotest.test_case
            "unopenable_target_does_not_claim_the_command_ran"
            `Quick
            test_unopenable_target_does_not_claim_the_command_ran
        ; Alcotest.test_case
            "ssh_redirect_is_named_and_never_opens_host_file"
            `Quick
            test_ssh_redirect_is_named_and_never_opens_host_file
        ] )
    ]
;;
