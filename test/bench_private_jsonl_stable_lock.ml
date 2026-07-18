let remove_if_present path =
  match Unix.unlink path with
  | () -> ()
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
;;

let with_jsonl_path f =
  let path = Filename.temp_file "masc_private_jsonl_lock_bench_" ".jsonl" in
  let output = open_out_bin path in
  output_string output "{\"row\":0}\n";
  close_out output;
  Fun.protect
    ~finally:(fun () ->
      remove_if_present path;
      remove_if_present (Fs_compat.private_jsonl_lock_path path))
    (fun () -> f path)
;;

let sync_parent_directory dir =
  let fd = Unix.openfile dir [ Unix.O_RDONLY; Unix.O_CLOEXEC ] 0 in
  Fun.protect ~finally:(fun () -> Unix.close fd) (fun () -> Unix.fsync fd)
;;

let percentile sorted fraction =
  let length = Array.length sorted in
  if length = 0
  then invalid_arg "percentile requires at least one sample"
  else (
    let rank = int_of_float (ceil (fraction *. float_of_int length)) in
    sorted.(max 0 (min (length - 1) (rank - 1))))
;;

let summarize samples =
  let sorted = Array.copy samples in
  Array.sort Float.compare sorted;
  percentile sorted 0.50, percentile sorted 0.95
;;

let measure iterations f =
  Array.init iterations (fun _ ->
    let started = Mtime_clock.now () in
    f ();
    Mtime.Span.to_float_ns (Mtime.span started (Mtime_clock.now ())) /. 1_000.0)
;;

let snapshot_or_fail ~io path =
  match
    Fs_compat.read_private_jsonl_durable_locked_with_io_for_testing
      ~io
      path
      ~after:None
  with
  | Ok snapshot -> snapshot
  | Error error -> failwith (Fs_compat.private_jsonl_transaction_error_to_string error)
;;

let append_or_fail ~io path cursor row =
  match
    Fs_compat.append_private_jsonl_durable_locked_at_cursor_with_io_for_testing
      ~io
      path
      ~expected:cursor
      row
  with
  | Ok cursor -> cursor
  | Error error -> failwith (Fs_compat.private_jsonl_transaction_error_to_string error)
;;

let benchmark_snapshot ~iterations ~warmup =
  with_jsonl_path @@ fun path ->
  let parent_sync_calls = ref 0 in
  let io : Fs_compat.private_jsonl_transaction_io_for_testing =
    { sync_parent =
        (fun dir ->
          incr parent_sync_calls;
          sync_parent_directory dir)
    }
  in
  ignore (snapshot_or_fail ~io path);
  for _ = 1 to warmup do
    ignore (snapshot_or_fail ~io path)
  done;
  parent_sync_calls := 0;
  let samples = measure iterations (fun () -> ignore (snapshot_or_fail ~io path)) in
  let p50_us, p95_us = summarize samples in
  p50_us, p95_us, !parent_sync_calls
;;

let benchmark_append ~iterations ~warmup =
  with_jsonl_path @@ fun path ->
  let parent_sync_calls = ref 0 in
  let io : Fs_compat.private_jsonl_transaction_io_for_testing =
    { sync_parent =
        (fun dir ->
          incr parent_sync_calls;
          sync_parent_directory dir)
    }
  in
  let cursor = ref (snapshot_or_fail ~io path).cursor in
  for _ = 1 to warmup do
    cursor := append_or_fail ~io path !cursor "{\"warmup\":true}\n"
  done;
  parent_sync_calls := 0;
  let samples =
    measure iterations (fun () ->
      cursor := append_or_fail ~io path !cursor "{\"measured\":true}\n")
  in
  let p50_us, p95_us = summarize samples in
  p50_us, p95_us, !parent_sync_calls
;;

let () =
  let iterations = ref 0 in
  let warmup = ref 0 in
  let options =
    [ "--iterations", Arg.Set_int iterations, "Measured operation count (required)"
    ; "--warmup", Arg.Set_int warmup, "Warmup operation count (required)"
    ]
  in
  Arg.parse options (fun argument -> raise (Arg.Bad ("unexpected argument: " ^ argument))) "";
  if !iterations <= 0 then raise (Arg.Bad "--iterations must be greater than zero");
  if !warmup <= 0 then raise (Arg.Bad "--warmup must be greater than zero");
  let snapshot_p50_us, snapshot_p95_us, snapshot_parent_sync_calls =
    benchmark_snapshot ~iterations:!iterations ~warmup:!warmup
  in
  let append_p50_us, append_p95_us, append_parent_sync_calls =
    benchmark_append ~iterations:!iterations ~warmup:!warmup
  in
  Printf.printf
    "{\"schema\":\"masc.private_jsonl.stable_lock.benchmark.v1\",\"iterations\":%d,\"warmup\":%d,\"snapshot\":{\"p50_us\":%.3f,\"p95_us\":%.3f,\"parent_sync_calls\":%d},\"append\":{\"p50_us\":%.3f,\"p95_us\":%.3f,\"parent_sync_calls\":%d}}\n%!"
    !iterations
    !warmup
    snapshot_p50_us
    snapshot_p95_us
    snapshot_parent_sync_calls
    append_p50_us
    append_p95_us
    append_parent_sync_calls
;;
