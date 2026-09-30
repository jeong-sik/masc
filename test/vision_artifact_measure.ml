(* Same-input vision artifact measurement, copied into each measured source tree. *)
open Masc
module V = Keeper_vision_tool
module Store = Multimodal.Vision_artifact_store

let fail msg = failwith msg
let get = function Ok x -> x | Error msg -> fail msg
let read path = In_channel.with_open_bin path In_channel.input_all
let write path body = Out_channel.with_open_bin path (fun out -> output_string out body)
let hash bytes = Digestif.SHA256.(digest_string bytes |> to_hex)
let now () = Unix.gettimeofday ()
type sample = {
  operation : string; fixture : string; outcome : string;
  start_epoch : float; end_epoch : float; elapsed_ms : float;
}
let sample ~fixture ~verify operation samples f =
  let start_epoch = now () in
  let result = f () in
  let end_epoch = now () in
  verify result;
  samples := { operation; fixture; outcome = "verified"; start_epoch; end_epoch;
               elapsed_ms = (end_epoch -. start_epoch) *. 1000. } :: !samples;
  result
let sample_json s =
  `Assoc ["operation", `String s.operation;
          "fixture", `String s.fixture;
          "outcome", `String s.outcome;
          "start_utc_epoch", `Float s.start_epoch;
          "end_utc_epoch", `Float s.end_epoch;
          "elapsed_ms", `Float s.elapsed_ms]
let sorted values = List.sort Float.compare values
let percentile values p =
  let values = Array.of_list (sorted values) in
  if Array.length values = 0 then 0. else
  values.(min (Array.length values - 1) (int_of_float (ceil (p *. float (Array.length values))) - 1))
let stats_float values =
  `Assoc ["count", `Int (List.length values);
          "p50_ms", `Float (percentile values 0.50);
          "p95_ms", `Float (percentile values 0.95);
          "p99_ms", `Float (percentile values 0.99);
          "max_ms", `Float (percentile values 1.0)]
let stats values = stats_float (List.map (fun s -> s.elapsed_ms) values)

let run ~root ~fixtures ~count ~window_seconds =
  Eio_main.run @@ fun env -> Eio.Switch.run @@ fun sw ->
  Eio_context.set_env env;
  Eio_context.with_test_env ~net:env#net ~clock:env#clock
    ~mono_clock:env#mono_clock ~sw @@ fun () ->
  Masc_test_deps.init_eio_clock ~sw env;
  Fs_compat.set_fs env#fs;
  let previous_pool = Domain_pool_ref.get () in
  Domain_pool_ref.set
    (Domain_pool.create ~sw ~domain_count:1 (Eio.Stdenv.domain_mgr env));
  Eio.Switch.on_release sw (fun () ->
    match previous_pool with Some p -> Domain_pool_ref.set p
    | None -> Domain_pool_ref.clear_for_tests ());
  Unix.putenv "MASC_BASE_PATH" root;
  Config_dir_resolver.reset ();
  let keeper = "vision-measure" in
  let meta = match Masc_test_deps.meta_of_json_fixture
    (`Assoc ["name", `String keeper]) with
    | Ok m -> m | Error msg -> fail msg in
  let frames = V.frames_dir ~keeper_name:keeper in
  let kept = V.vision_store_dir ~keeper_name:keeper in
  Fs_compat.mkdir_p frames;
  for i = 0 to 499 do
    let bytes = read (Filename.concat fixtures (Printf.sprintf "%04d.png" i)) in
    ignore (get (Store.store ~auto_prune:false ~dir:frames bytes))
  done;
  let check_load_error handle expected =
    let args = `Assoc ["artifact", `String handle; "query", `String "check";
                       "media_type", `String "invalid/measurement"] in
    let result = V.handle_with_outcome ~sw ~clock:env#clock ~net:env#net
      ~meta ~args () in
    let output = Yojson.Safe.from_string result.raw_output in
    if Yojson.Safe.Util.member "error" output <> `String expected then
      fail ("wrong load error: " ^ result.raw_output) in
  check_load_error "../invalid" "invalid_artifact";
  check_load_error (String.make 64 '0') "artifact_not_found";
  let corrupt = read (Filename.concat fixtures "0540.png") in
  let corrupt_handle = get (V.store_kept ~keeper_name:keeper corrupt)
    |> Store.to_string in
  write (Filename.concat kept corrupt_handle) "corrupt";
  check_load_error corrupt_handle "artifact_load_failed";
  let frame_samples = ref [] and kept_new = ref [] and kept_repeat = ref [] in
  let load_kept = ref [] and load_frame = ref [] and lag = ref [] in
  write (Filename.concat root "window-ready") (string_of_float (now ()));
  while not (Sys.file_exists (Filename.concat root "window-go")) do
    Eio.Time.sleep env#clock 0.01
  done;
  let running = ref true in
  Eio.Fiber.fork ~sw (fun () ->
    let interval = 0.005 in
    let expected = ref (now () +. interval) in
    while !running do
      Eio.Time.sleep env#clock interval;
      lag := (max 0. ((now () -. !expected) *. 1000.)) :: !lag;
      expected := now () +. interval
    done);
  let finish () = running := false in
  Fun.protect ~finally:finish (fun () ->
    let check_file dir bytes handle =
      let actual = Store.to_string handle in
      if actual <> hash bytes then fail "returned handle differs from input SHA-256";
      if read (Filename.concat dir actual) <> bytes then fail "stored bytes differ";
      actual in
    let load handle =
      let args = `Assoc [
        "artifact", `String handle; "query", `String "measurement";
        "media_type", `String "invalid/measurement"] in
      V.handle_with_outcome ~sw ~clock:env#clock ~net:env#net ~meta ~args () in
    let verify_load (result : Keeper_tool_execution.t) =
      let output = Yojson.Safe.from_string result.raw_output in
      if Yojson.Safe.Util.member "error" output <>
         `String "invalid_media_type" then
        fail ("load did not reach media validation: " ^ result.raw_output) in
    let window_start = now () in
    write (Filename.concat root "window-start") (string_of_float window_start);
    let first_fixture = "0000.png" in
    let first = read (Filename.concat fixtures first_fixture) in
    let first_name = ref "" in
    ignore (sample ~fixture:first_fixture
      ~verify:(fun handle -> first_name := check_file kept first handle)
      "store_kept_new" kept_new (fun () ->
        get (V.store_kept ~keeper_name:keeper first)));
    ignore (sample ~fixture:first_fixture
      ~verify:(fun handle -> ignore (check_file kept first handle))
      "store_kept_repeat" kept_repeat (fun () ->
        get (V.store_kept ~keeper_name:keeper first)));
    ignore (sample ~fixture:first_fixture ~verify:verify_load
      "load_kept" load_kept (fun () -> load !first_name));
    for i = 1 to count do
      let due = window_start +. (float i *. window_seconds /. float count) in
      let delay = due -. now () in
      if delay > 0. then Eio.Time.sleep env#clock delay;
      let fixture = Printf.sprintf "%04d.png" (499 + i) in
      let bytes = read (Filename.concat fixtures fixture) in
      let name = ref "" in
      ignore (sample ~fixture
        ~verify:(fun handle -> name := check_file frames bytes handle)
        "store_frame" frame_samples (fun () ->
          get (V.store_frame ~keeper_name:keeper bytes)));
      ignore (sample ~fixture ~verify:verify_load
        "load_frame" load_frame (fun () -> load !name));
      let kept_name = ref "" in
      ignore (sample ~fixture
        ~verify:(fun handle -> kept_name := check_file kept bytes handle)
        "store_kept_new" kept_new (fun () ->
          get (V.store_kept ~keeper_name:keeper bytes)));
      ignore (sample ~fixture
        ~verify:(fun handle -> ignore (check_file kept bytes handle))
        "store_kept_repeat" kept_repeat (fun () ->
          get (V.store_kept ~keeper_name:keeper bytes)));
      ignore (sample ~fixture ~verify:verify_load
        "load_kept" load_kept (fun () -> load !kept_name))
    done;
    let files = Array.to_list (Sys.readdir frames)
      |> List.filter (fun n -> String.length n = 64) in
    let bytes = List.fold_left (fun acc name ->
      acc + (Unix.stat (Filename.concat frames name)).Unix.st_size) 0 files in
    if List.length files > Store.default_max_entries ||
       bytes > Store.default_max_bytes then
      fail "frame retention limit exceeded";
    let output = `Assoc [
      "source", `String (Sys.getenv "MEASURE_SOURCE");
      "window_start_utc_epoch", `Float window_start;
      "input_count", `Int count;
      "frame_entries", `Int (List.length files);
      "frame_bytes", `Int bytes;
      "store_frame", stats !frame_samples;
      "store_kept_new", stats !kept_new;
      "store_kept_repeat", stats !kept_repeat;
      "load_kept", stats !load_kept;
      "load_frame", stats !load_frame;
      "scheduler_lag", stats_float !lag;
      "samples", `List (List.map sample_json
        (List.sort (fun a b -> Float.compare a.start_epoch b.start_epoch)
          (!frame_samples @ !kept_new @ !kept_repeat @ !load_kept @ !load_frame)))] in
    let window_end = now () in
    write (Filename.concat root "window-complete") (string_of_float window_end);
    while not (Sys.file_exists (Filename.concat root "window-release")) do
      Eio.Time.sleep env#clock 0.01
    done;
    print_endline (Yojson.Safe.to_string output))

let () =
  if Array.length Sys.argv <> 5 then
    fail "usage: vision_artifact_measure ROOT FIXTURES COUNT WINDOW_SECONDS";
  run ~root:Sys.argv.(1) ~fixtures:Sys.argv.(2)
    ~count:(int_of_string Sys.argv.(3))
    ~window_seconds:(float_of_string Sys.argv.(4))
