(* Not a test: prints how late a fiber of the calling domain wakes while other
   fibers of that domain hand JSON work to [Systhread_host.run].

     bench_systhread_cpu_work MODE SECONDS FIBERS KILOBYTES

   MODE own    no [Systhread_host]: the work's thread belongs to the calling
               domain, as under [Eio_unix.run_in_systhread]
        host   [Systhread_host] is started first, so that thread is on its
               domain
   FIBERS      fibers that hand over one piece of work, wait for it and pause;
               0 gives the floor of this machine
   KILOBYTES   size of the JSON text each piece of work parses and encodes

   The probe sleeps 5 ms and then calls [Unix.stat], a system call that lets
   go of the domain lock and takes it again, as a fiber's own file calls do.
   One line per run: pieces of work per second and the probe's lateness in
   ms. Run the modes in turn, several times, and note the host's load: a
   loaded machine moves the tail of both. *)

let now () = Unix.gettimeofday ()
let probe_interval_s = 0.005
let pause_between_work_s = 0.02

let percentile sorted fraction =
  let count = Array.length sorted in
  sorted.(min (count - 1) (int_of_float (ceil (fraction *. float_of_int count)) - 1))
;;

(* Text with the escapes source code carries, so the parser takes the same
   path as on a retained tool request. *)
let document kilobytes =
  let line = "let rec go = function\n\t| [] -> \"done\"\n\t| _ :: rest -> go rest\n" in
  let lines = kilobytes * 1024 / String.length line in
  Yojson.Safe.to_string
    (`Assoc [ "request", `List (List.init lines (fun _ -> `String line)) ])
;;

let work text () =
  let encoded = Yojson.Safe.to_string (Yojson.Safe.from_string text) in
  ignore (Digest.string encoded : Digest.t)
;;

let () =
  let mode = Sys.argv.(1) in
  let seconds = float_of_string Sys.argv.(2) in
  let fibers = int_of_string Sys.argv.(3) in
  let text = document (int_of_string Sys.argv.(4)) in
  (match mode with
   | "own" -> ()
   | "host" -> Systhread_host.start ()
   | other -> failwith ("mode is own or host, not " ^ other));
  Eio_main.run
  @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  let stop_at = now () +. seconds in
  let lateness_ms = ref [] in
  let pieces = ref 0 in
  Eio.Switch.run
  @@ fun sw ->
  for _ = 1 to fibers do
    Eio.Fiber.fork ~sw (fun () ->
      while now () < stop_at do
        Systhread_host.run ~label:"bench-json-work" (work text);
        incr pieces;
        Eio.Time.sleep clock pause_between_work_s
      done)
  done;
  while now () < stop_at do
    let before = now () in
    Eio.Time.sleep clock probe_interval_s;
    ignore (Unix.stat "." : Unix.stats);
    lateness_ms := ((now () -. before -. probe_interval_s) *. 1000.0) :: !lateness_ms
  done;
  let sorted = Array.of_list !lateness_ms in
  Array.sort Float.compare sorted;
  Printf.printf
    "%-4s fibers=%d kb=%s work/s=%.0f late_ms p50=%.2f p95=%.2f p99=%.2f max=%.2f samples=%d\n"
    mode
    fibers
    Sys.argv.(4)
    (float_of_int !pieces /. seconds)
    (percentile sorted 0.50)
    (percentile sorted 0.95)
    (percentile sorted 0.99)
    sorted.(Array.length sorted - 1)
    (Array.length sorted)
;;
