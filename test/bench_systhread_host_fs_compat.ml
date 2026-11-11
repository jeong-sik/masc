(* Not a test: prints how late a fiber of the calling domain wakes while other
   fibers of that domain run durable rewrites through [Fs_compat].

     bench_systhread_host_fs_compat MODE SECONDS FIBERS KILOBYTES BLOCKED_DOMAINS DIR

   MODE own    [Fs_compat]'s blocking calls start their threads on the calling
               domain, as they did before [Systhread_host] sat below it
        host   [Systhread_host] is started first, so they run on its domain
   FIBERS      fibers that rewrite; 0 gives the floor of this machine
   KILOBYTES   size of the JSON document each rewrite parses and writes back
   BLOCKED_DOMAINS
               domains that sit blocked, as most of a server's do between
               jobs; each still answers every stop-the-world minor collection

   One line per run: rewrites per second and the probe's lateness in ms. Run
   the two modes in turn, several times, and note the host's load: a loaded
   machine moves the tail of both. *)

let now () = Unix.gettimeofday ()
let probe_interval_s = 0.005
let pause_between_rewrites_s = 0.004
let bytes_per_row = 120

let document ~kilobytes =
  let row = `Assoc [ "k", `String (String.make 96 'x'); "n", `Int 1 ] in
  let rows = max 1 (kilobytes * 1024 / bytes_per_row) in
  Yojson.Safe.to_string (`List (List.init rows (fun _ -> row)))
;;

(* [decide] runs inside the blocking call: the parse and the encoding are the
   OCaml work that holds a domain's lock. *)
let rewrite path ~initial =
  match
    Fs_compat.rewrite_private_file_durable_locked_result path (fun existing ->
      let text = if String.equal existing "" then initial else existing in
      Some (Yojson.Safe.to_string (Yojson.Safe.from_string text)), ())
  with
  | Ok () -> ()
  | Error message -> failwith message
;;

let block_forever () =
  let mutex = Mutex.create () in
  let never = Condition.create () in
  Mutex.lock mutex;
  while true do
    Condition.wait never mutex
  done
;;

let percentile sorted fraction =
  let count = Array.length sorted in
  sorted.(min (count - 1) (int_of_float (ceil (fraction *. float_of_int count)) - 1))
;;

let () =
  let mode = Sys.argv.(1) in
  let seconds = float_of_string Sys.argv.(2) in
  let fibers = int_of_string Sys.argv.(3) in
  let kilobytes = int_of_string Sys.argv.(4) in
  let blocked_domains = int_of_string Sys.argv.(5) in
  let dir = Sys.argv.(6) in
  (match mode with
   | "own" -> ()
   | "host" -> Systhread_host.start ()
   | other -> failwith ("mode is own or host, not " ^ other));
  for _ = 1 to blocked_domains do
    ignore (Domain.spawn block_forever : unit Domain.t)
  done;
  let initial = document ~kilobytes in
  Eio_main.run
  @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  let stop_at = now () +. seconds in
  let lateness_ms = ref [] in
  let rewrites = ref 0 in
  Eio.Switch.run
  @@ fun sw ->
  for fiber = 1 to fibers do
    let path = Filename.concat dir (Printf.sprintf "store-%d.json" fiber) in
    Eio.Fiber.fork ~sw (fun () ->
      while now () < stop_at do
        rewrite path ~initial;
        incr rewrites;
        Eio.Time.sleep clock pause_between_rewrites_s
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
    "%-4s fibers=%d kb=%d blocked_domains=%d rewrites/s=%.0f late_ms p50=%.2f p95=%.2f \
     p99=%.2f max=%.2f samples=%d\n"
    mode
    fibers
    kilobytes
    blocked_domains
    (float_of_int !rewrites /. seconds)
    (percentile sorted 0.50)
    (percentile sorted 0.95)
    (percentile sorted 0.99)
    sorted.(Array.length sorted - 1)
    (Array.length sorted)
;;
