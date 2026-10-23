(* Isolated scheduling experiment; no MASC process or storage is used.
   canonical/hash match workspace_memory_context.ml at 33e3dcd9bf6. *)
let rec canonical = function
  | `Assoc fields -> `Assoc (List.map (fun (key, value) -> key, canonical value) fields
      |> List.sort (fun (a, _) (b, _) -> String.compare a b))
  | `List values -> `List (List.map canonical values)
  | value -> value
let hash value = Digestif.SHA256.(digest_string (Yojson.Safe.to_string (canonical value)) |> to_hex)

let observe env pool ~mode ~bytes ~round =
  let value = `Assoc ["payload", `String (String.make bytes 'x'); "revision", `Int 1] in
  let finished = Atomic.make false in
  let gaps = ref [] and result = ref None in
  let clock = Eio.Stdenv.clock env in
  let started = Unix.gettimeofday () in
  Eio.Fiber.both
    (fun () ->
      let rec tick () =
        let before = Eio.Time.now clock in
        Eio.Time.sleep clock 0.001;
        gaps := ((Eio.Time.now clock -. before) *. 1000.) :: !gaps;
        if not (Atomic.get finished) then tick () in
      tick ())
    (fun () ->
      Eio.Fiber.yield ();
      let work () = Eio_unix.run_in_systhread ~label:"context-canonical-hash" (fun () -> hash value) in
      let digest = match mode with
        | `Systhread -> work ()
        | `Cpu_worker -> (match Eio.Executor_pool.submit pool ~weight:1.0 work with
            | Ok digest -> digest | Error error -> raise error) in
      result := Some digest;
      Atomic.set finished true);
  let elapsed_ms = (Unix.gettimeofday () -. started) *. 1000. in
  let mode = match mode with `Systhread -> "calling-domain-systhread" | `Cpu_worker -> "cpu-worker-systhread" in
  Yojson.Safe.to_channel stdout (`Assoc ["mode",`String mode;"bytes",`Int bytes;"round",`Int round;
    "elapsed_ms",`Float elapsed_ms;"max_tick_gap_ms",`Float (List.fold_left max 0. !gaps);
    "ticks",`Int (List.length !gaps);"digest",(match !result with Some d -> `String d | None -> `Null)]);
  output_char stdout '\n'; flush stdout

let () = Eio_main.run (fun env -> Eio.Switch.run (fun sw ->
  let pool = Eio.Executor_pool.create ~sw ~domain_count:1 (Eio.Stdenv.domain_mgr env) in
  List.iter (fun bytes -> for round = 1 to 3 do
    let modes = if round mod 2 = 0 then [`Cpu_worker;`Systhread] else [`Systhread;`Cpu_worker] in
    List.iter (fun mode -> observe env pool ~mode ~bytes ~round) modes
  done) [1024*1024;8*1024*1024]))
