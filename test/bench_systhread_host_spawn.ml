(* Not a test: prints how late a fiber of the calling domain wakes while other
   fibers of that domain start children through [Posix_spawn_process_mgr].

     bench_systhread_host_spawn MODE SECONDS FIBERS

   MODE own    no [Systhread_host]: the spawn call's thread belongs to the
               calling domain
        host   [Systhread_host] is started first, so that thread is on its
               domain
   FIBERS      fibers that start /usr/bin/true and await it; 0 gives the floor
               of this machine

   One line per run: children per second and the probe's lateness in ms. Run
   the modes in turn, several times, and note the host's load: a loaded
   machine moves the tail of both. *)

let now () = Unix.gettimeofday ()
let probe_interval_s = 0.005
let pause_between_spawns_s = 0.004

let percentile sorted fraction =
  let count = Array.length sorted in
  sorted.(min (count - 1) (int_of_float (ceil (fraction *. float_of_int count)) - 1))
;;

let () =
  let mode = Sys.argv.(1) in
  let seconds = float_of_string Sys.argv.(2) in
  let fibers = int_of_string Sys.argv.(3) in
  (match mode with
   | "own" -> ()
   | "host" -> Systhread_host.start ()
   | other -> failwith ("mode is own or host, not " ^ other));
  Eio_main.run
  @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  let stop_at = now () +. seconds in
  let lateness_ms = ref [] in
  let children = ref 0 in
  Eio.Switch.run
  @@ fun sw ->
  for _ = 1 to fibers do
    Eio.Fiber.fork ~sw (fun () ->
      while now () < stop_at do
        Eio.Process.run Posix_spawn_process_mgr.mgr [ "/usr/bin/true" ];
        incr children;
        Eio.Time.sleep clock pause_between_spawns_s
      done)
  done;
  while now () < stop_at do
    let before = now () in
    Eio.Time.sleep clock probe_interval_s;
    lateness_ms := ((now () -. before -. probe_interval_s) *. 1000.0) :: !lateness_ms
  done;
  let sorted = Array.of_list !lateness_ms in
  Array.sort Float.compare sorted;
  Printf.printf
    "%-4s fibers=%d children/s=%.0f late_ms p50=%.2f p95=%.2f p99=%.2f max=%.2f samples=%d\n"
    mode
    fibers
    (float_of_int !children /. seconds)
    (percentile sorted 0.50)
    (percentile sorted 0.95)
    (percentile sorted 0.99)
    sorted.(Array.length sorted - 1)
    (Array.length sorted)
;;
