(* A prepared-response gate microbenchmark, not an HTTP/server benchmark.
   Authority is reread on every iteration; only the supplied read clock is
   controlled. Use an isolated base path, never a writable production fixture. *)
let () =
  let base_path = ref "" and snapshot = ref "" and samples = ref 200 in
  let at = ref 1790640000. and step_s = ref 2. in
  Arg.parse
    [ "--base-path", Arg.Set_string base_path, "Isolated authority fixture";
      "--snapshot", Arg.Set_string snapshot, "Frozen execution JSON";
      "--samples", Arg.Set_int samples, "Number of consecutive reads";
      "--at", Arg.Set_float at, "First authoritative read time (epoch seconds)";
      "--step-s", Arg.Set_float step_s, "Advance each read clock by this many seconds" ]
    (fun _ -> raise (Arg.Bad "unexpected positional argument"))
    "Prepared-response observation gate benchmark";
  if !base_path = "" || !snapshot = "" || !samples <= 0 || !step_s < 0. then
    raise (Arg.Bad "provide a base path, snapshot, positive samples and nonnegative clock step");
  let config = Masc.Workspace.default_config !base_path in
  Candle_status.install_appraiser_check (fun () -> Ok ());
  let seed = Yojson.Safe.from_file !snapshot in
  let rows = match Yojson.Safe.Util.member "keepers" seed with
    | `List rows -> rows
    | `Assoc fields -> (match List.assoc_opt "items" fields with
        | Some (`List rows) -> rows
        | Some _ | None -> invalid_arg "execution Keeper items must be an array")
    | _ -> invalid_arg "snapshot must be an execution object with Keeper rows" in
  if not (List.exists (fun row -> match Yojson.Safe.Util.member "name" row with
      | `String name -> name <> ""
      | _ -> false) rows) then
    invalid_arg "snapshot must contain a named Keeper";
  let read index () =
    let observation = Candle_observe.read
      ~now:(fun () -> !at +. float_of_int index *. !step_s) ~base_path:!base_path in
    (match Candle_observe.summary observation with
     | Candle_observation.Ready _ -> ()
     | Candle_observation.Off | Candle_observation.Disabled _ ->
       invalid_arg "benchmark requires readable, enabled Candle authority");
    observation
  in
  let project index json =
    Dashboard_projection_cache.For_test.with_current_keeper_observations
      ~read:(read index)
      ~config json in
  let cached_json = ref (project 0 seed) in
  let first_candle = Yojson.Safe.Util.member "candle" !cached_json in
  let cached_body = ref (Yojson.Safe.to_string !cached_json) in
  let reused = ref 0 and encoded = ref 0 in
  Gc.full_major ();
  let gc_before = Gc.quick_stat () in
  let timings = List.init !samples (fun index ->
    let counter = Mtime_clock.counter () in
    let projected = project (index + 1) !cached_json in
    if projected = !cached_json then incr reused
    else begin
      incr encoded;
      cached_json := projected;
      cached_body := Yojson.Safe.to_string projected
    end;
    Mtime.Span.to_float_ns (Mtime_clock.count counter) /. 1e6) in
  let gc_after = Gc.quick_stat () in
  let sorted = List.sort Float.compare timings in
  let quantile fraction = List.nth sorted (int_of_float (ceil (fraction *. float_of_int !samples)) - 1) in
  let allocated_words stat = stat.Gc.minor_words +. stat.Gc.major_words -. stat.Gc.promoted_words in
  let result = `Assoc [
    "scope", `String "isolated prepared-response gate; not live HTTP latency";
    "first_candle", first_candle;
    "last_candle", Yojson.Safe.Util.member "candle" !cached_json;
    "keeper_rows", `Int (List.length rows);
    "samples", `Int !samples; "clock_step_s", `Float !step_s;
    "reused", `Int !reused; "encoded", `Int !encoded;
    "response_bytes", `Int (String.length !cached_body);
    "p50_ms", `Float (quantile 0.50); "p95_ms", `Float (quantile 0.95);
    "max_ms", `Float (List.hd (List.rev sorted));
    "total_ms", `Float (List.fold_left (+.) 0. timings);
    "allocated_words", `Float (allocated_words gc_after -. allocated_words gc_before) ] in
  print_endline (Yojson.Safe.to_string result)
