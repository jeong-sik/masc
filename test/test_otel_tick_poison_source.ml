(* Regression guard: once the OTEL tick path hits Eio.Mutex.Poisoned, the
   backend is already degraded. The tick fiber must stop instead of logging the
   same poisoned mutex failure on every scheduled tick. *)

let read_file path =
  let ic = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () -> In_channel.input_all ic)

let position haystack needle =
  let n = String.length needle in
  let h = String.length haystack in
  let rec scan i =
    if i + n > h then None
    else if String.sub haystack i n = needle then Some i
    else scan (i + 1)
  in
  scan 0

let contains haystack needle =
  match position haystack needle with
  | Some _ -> true
  | None -> false

let assert_contains ~label haystack needle =
  if not (contains haystack needle)
  then failwith (Printf.sprintf "[%s] expected source to contain %S" label needle)

let assert_not_contains ~label haystack needle =
  if contains haystack needle
  then failwith (Printf.sprintf "[%s] expected source not to contain %S" label needle)

let assert_order ~label haystack first second =
  match position haystack first, position haystack second with
  | Some a, Some b when a < b -> ()
  | _ ->
    failwith
      (Printf.sprintf
         "[%s] expected %S to appear before %S in opentelemetry_client_cohttp_eio.ml"
         label
         first
         second)

let source () =
  let parent p = Filename.dirname p in
  let exe = Sys.executable_name in
  let project_root = parent (parent (parent (parent exe))) in
  let rel = "lib/otel_spans/opentelemetry_client_cohttp_eio.ml" in
  let candidates =
    [ Filename.concat project_root rel
    ; rel
    ; Filename.concat ".." rel
    ]
  in
  match List.find_opt Sys.file_exists candidates with
  | Some path -> read_file path
  | None ->
    failwith
      (Printf.sprintf
         "no opentelemetry_client_cohttp_eio.ml source path resolved (cwd=%s, exe=%s)"
         (Sys.getcwd ())
         exe)

let () =
  let src = source () in
  let helper = "let stop_tick_after_poisoned_mutex ~stop cause =" in
  let stop_flag = "Atomic.set stop true" in
  let degraded_state = "Atomic.set tick_degraded_state true" in
  let degradation_error = "Atomic.set last_tick_poisoned_error_state" in
  let degraded_log_prefix = "OTEL metrics \\" in
  let degraded_log_suffix = "export degraded until backend restart" in
  let poison_catch =
    "| Eio.Mutex.Poisoned cause -> stop_tick_after_poisoned_mutex ~stop cause"
  in
  let local_post = "Httpc.post" in
  let global_pool_post = "Masc_http_client.post_sync" in
  assert_contains ~label:"poison helper" src helper;
  assert_contains ~label:"poison helper stops tick loop" src stop_flag;
  assert_contains ~label:"poison helper records degraded state" src degraded_state;
  assert_contains ~label:"poison helper records degradation cause" src degradation_error;
  assert_contains ~label:"poison log explains degradation prefix" src degraded_log_prefix;
  assert_contains ~label:"poison log explains degradation suffix" src degraded_log_suffix;
  assert_contains ~label:"tick catch delegates to poison helper" src poison_catch;
  assert_contains ~label:"otel uses local cohttp client" src local_post;
  assert_not_contains ~label:"otel avoids process-global http pool" src global_pool_post;
  assert_order ~label:"stop before degraded log" src stop_flag degraded_log_prefix;
  assert_order ~label:"helper before catch" src helper poison_catch;
  print_endline "test_otel_tick_poison_source: OK"
