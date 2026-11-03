open Alcotest

let describe = function
  | Ok value -> Ok value
  | Error failure -> Error (Forked_map.failure_to_string failure)

let outcomes testable = list (result testable string)

let read path = In_channel.with_open_bin path In_channel.input_all
let write path text = Out_channel.with_open_bin path (fun out -> output_string out text)

let rec remove_tree path =
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  | { Unix.st_kind = Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK; _ } ->
    Sys.remove path
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()

let with_temp_dir f =
  let directory = Filename.temp_dir "forked-map-test-" "" in
  Fun.protect ~finally:(fun () -> remove_tree directory) (fun () -> f directory)

let contains text part =
  let length = String.length part in
  let rec from index =
    index + length <= String.length text
    && (String.equal (String.sub text index length) part || from (index + 1))
  in
  from 0

let test_results_follow_job_order () =
  let started = ref [] and delivered = ref [] in
  (* The first job takes longest, so the last job finishes first. *)
  let job index () =
    Unix.sleepf (0.15 -. (0.04 *. float_of_int index));
    index * 10
  in
  let results =
    Forked_map.map
      ~jobs:4
      ~on_start:(fun index -> started := index :: !started)
      ~on_result:(fun index _ -> delivered := index :: !delivered)
      (List.init 4 job)
  in
  check (outcomes int) "results are in job order" [ Ok 0; Ok 10; Ok 20; Ok 30 ]
    (List.map describe results);
  check (list int) "every job started" [ 0; 1; 2; 3 ] (List.sort compare !started);
  check (list int) "results were delivered in job order" [ 0; 1; 2; 3 ] (List.rev !delivered)

let test_a_raising_job_does_not_stop_the_others () =
  let results =
    Forked_map.map
      ~jobs:3
      [ (fun () -> 1); (fun () -> failwith "boom"); (fun () -> 3) ]
  in
  check (outcomes int) "the raise is reported for its own job only"
    [ Ok 1; Error "Failure(\"boom\")"; Ok 3 ]
    (List.map describe results)

let test_a_process_that_dies_is_reported () =
  let results =
    Forked_map.map
      ~jobs:3
      [ (fun () -> Unix.kill (Unix.getpid ()) Sys.sigkill; 0)
      ; (fun () -> Unix._exit 3)
      ; (fun () -> 7)
      ]
  in
  check (outcomes int) "a killed process, an early exit and a normal result"
    [ Error "the process was ended by SIGKILL without a result"
    ; Error "the process exited with status 3 without a result"
    ; Ok 7
    ]
    (List.map describe results)

let test_a_result_larger_than_a_pipe_comes_back () =
  let size = 5_000_000 in
  let results =
    Forked_map.map ~jobs:2 [ (fun () -> String.make size 'x'); (fun () -> "small") ]
  in
  check (outcomes int) "the large result arrives whole"
    [ Ok size; Ok (String.length "small") ]
    (List.map (fun result -> Result.map String.length (describe result)) results)

let test_one_job_runs_in_this_process () =
  let here = Unix.getpid () in
  let pids ~jobs =
    Forked_map.map ~jobs [ (fun () -> Unix.getpid ()); (fun () -> Unix.getpid ()) ]
    |> List.map describe
  in
  check (outcomes int) "jobs=1 stays in this process" [ Ok here; Ok here ] (pids ~jobs:1);
  check bool "jobs=2 uses other processes" true
    (List.for_all
       (function
         | Ok pid -> pid <> here
         | Error _ -> false)
       (pids ~jobs:2))

let test_at_most_jobs_run_at_once () =
  with_temp_dir @@ fun directory ->
  let log = Filename.concat directory "log" in
  let job () =
    (* One small append is one write, so lines from different jobs never mix. *)
    let append text =
      let fd = Unix.openfile log [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_APPEND ] 0o600 in
      ignore (Unix.write_substring fd text 0 (String.length text));
      Unix.close fd
    in
    append "+";
    Unix.sleepf 0.1;
    append "-"
  in
  let results = Forked_map.map ~jobs:2 (List.init 6 (fun _ -> job)) in
  check bool "every job returned" true
    (List.for_all (function Ok () -> true | Error _ -> false) results);
  let peak, _ =
    String.fold_left
      (fun (peak, alive) mark ->
         let alive = if mark = '+' then alive + 1 else alive - 1 in
         max peak alive, alive)
      (0, 0)
      (read log)
  in
  check bool "never more than two at once" true (peak <= 2);
  check bool "two did run together" true (peak = 2)

let test_an_unusable_result_directory_fails_every_job () =
  with_temp_dir @@ fun directory ->
  let marker = Filename.concat directory "ran" in
  let saved = Filename.get_temp_dir_name () in
  Filename.set_temp_dir_name (Filename.concat directory "missing");
  let results =
    Fun.protect
      ~finally:(fun () -> Filename.set_temp_dir_name saved)
      (fun () ->
         Forked_map.map
           ~jobs:2
           [ (fun () -> write marker "ran"; 1); (fun () -> write marker "ran"; 2) ])
  in
  check bool "no job ran" false (Sys.file_exists marker);
  check bool "every job says why it did not run" true
    (List.for_all
       (function
         | Error (Forked_map.Raised detail) ->
           contains detail "cannot create the directory for results"
         | Error (Forked_map.Died _ | Forked_map.Never_ran) | Ok _ -> false)
       results);
  check int "one result per job" 2 (List.length results)

let with_stdout_to path f =
  flush_all ();
  let saved = Unix.dup Unix.stdout in
  let target = Unix.openfile path [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ] 0o600 in
  Unix.dup2 target Unix.stdout;
  Unix.close target;
  Fun.protect
    ~finally:(fun () ->
      flush_all ();
      Unix.dup2 saved Unix.stdout;
      Unix.close saved)
    f

let test_text_printed_before_the_fork_is_not_printed_again () =
  with_temp_dir @@ fun directory ->
  let path = Filename.concat directory "stdout" in
  (* A child that prints and flushes also writes whatever its parent had
     buffered at the fork, unless the parent flushed first. *)
  let job () =
    print_string "job\n";
    flush stdout;
    1
  in
  with_stdout_to path (fun () ->
    print_string "printed once\n";
    ignore (Forked_map.map ~jobs:2 [ job; job; job ]));
  let lines = String.split_on_char '\n' (read path) |> List.filter (fun line -> line <> "") in
  check (list string) "the buffered text reached the file once, then one line per job"
    [ "printed once"; "job"; "job"; "job" ] lines

let process_is_gone pid =
  match Unix.kill pid 0 with
  | () -> false
  | exception Unix.Unix_error (error, _, _) -> error = Unix.ESRCH

let wait_until what condition =
  let deadline = Unix.gettimeofday () +. 10. in
  let rec loop () =
    if condition () then ()
    else if Unix.gettimeofday () > deadline then fail ("timed out waiting for " ^ what)
    else (
      Unix.sleepf 0.02;
      loop ())
  in
  loop ()

let test_ending_the_caller_ends_its_children () =
  with_temp_dir @@ fun directory ->
  let scratch = Filename.concat directory "scratch" in
  Unix.mkdir scratch 0o700;
  let pid_files = List.init 2 (fun i -> Filename.concat directory (Printf.sprintf "job%d" i)) in
  match Unix.fork () with
  | 0 ->
    Filename.set_temp_dir_name scratch;
    (try
       ignore
         (Forked_map.map
            ~jobs:2
            (List.map
               (fun path () ->
                  write path (string_of_int (Unix.getpid ()));
                  Unix.sleep 60)
               pid_files))
     with
     | _ -> ());
    Unix._exit 0
  | driver ->
    wait_until "both jobs to start" (fun () ->
      List.for_all (fun path -> Sys.file_exists path && read path <> "") pid_files);
    let job_pids = List.map (fun path -> int_of_string (read path)) pid_files in
    Unix.kill driver Sys.sigterm;
    let _, status = Unix.waitpid [] driver in
    check bool "the caller ended by the signal it received" true
      (status = Unix.WSIGNALED Sys.sigterm);
    wait_until "the children to end" (fun () -> List.for_all process_is_gone job_pids);
    check (list string) "the result files were removed" [] (Array.to_list (Sys.readdir scratch))

let () =
  run "test_forked_map"
    [ ( "forked map"
      , [ test_case "results follow job order" `Quick test_results_follow_job_order
        ; test_case "a raising job does not stop the others" `Quick
            test_a_raising_job_does_not_stop_the_others
        ; test_case "a process that dies is reported" `Quick
            test_a_process_that_dies_is_reported
        ; test_case "a result larger than a pipe comes back" `Quick
            test_a_result_larger_than_a_pipe_comes_back
        ; test_case "one job runs in this process" `Quick test_one_job_runs_in_this_process
        ; test_case "at most jobs run at once" `Quick test_at_most_jobs_run_at_once
        ; test_case "text printed before the fork is not printed again" `Quick
            test_text_printed_before_the_fork_is_not_printed_again
        ; test_case "ending the caller ends its children" `Quick
            test_ending_the_caller_ends_its_children
        ; test_case "an unusable result directory fails every job" `Quick
            test_an_unusable_result_directory_fails_every_job
        ] )
    ]
