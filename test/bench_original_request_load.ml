(* Not a test: prints how late a fiber of the calling domain wakes while
   another fiber of that domain loads retained original requests.

     bench_original_request_load MODE SECONDS KILOBYTES

   MODE own    no domain pool: the load checks the body on the calling domain
        pool   a domain pool of one domain is set first, so the check is a
               job of that pool
        idle   nothing is loaded; the floor of this machine
   KILOBYTES   size of each retained request's body

   Sixteen requests are retained in a store under a temporary directory and
   one fiber loads them in turn until the time is up. The probe sleeps 5 ms.
   One line per run: loads per second and the probe's lateness in ms. Run the
   modes in turn, several times, and note the host's load. *)

open Masc
module Owner = Lane_addon_tool_request_owner

let now () = Unix.gettimeofday ()
let probe_interval_s = 0.005
let scope = "bench-original-request-load"
let retained_requests = 16

let percentile sorted fraction =
  let count = Array.length sorted in
  sorted.(min (count - 1) (int_of_float (ceil (fraction *. float_of_int count)) - 1))
;;

(* Text with the escapes source code carries, as a tool request's input has. *)
let request ~index kilobytes =
  let line = "let rec go = function\n\t| [] -> \"done\"\n\t| _ :: rest -> go rest\n" in
  let lines = kilobytes * 1024 / String.length line in
  `Assoc [ "index", `Int index; "input", `List (List.init lines (fun _ -> `String line)) ]
;;

let request_id index = Printf.sprintf "request-%02d" index

let rec remove path =
  match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR ->
    Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  | Unix.S_REG | Unix.S_LNK | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK -> Sys.remove path
;;

let fail_on_error = function
  | Ok value -> value
  | Error error -> failwith (Owner.error_to_string error)
;;

let () =
  let mode = Sys.argv.(1) in
  let seconds = float_of_string Sys.argv.(2) in
  let kilobytes = int_of_string Sys.argv.(3) in
  let parent = Filename.temp_dir "bench-original-request" "" in
  Fun.protect ~finally:(fun () -> remove parent) (fun () ->
    let store = Lane_addon_store.create ~root:(Filename.concat parent "store") in
    for index = 0 to retained_requests - 1 do
      fail_on_error
        (Owner.retain ~store ~scope ~request_id:(request_id index) ~installation_id:"bench"
           ~package_id:"bench" ~tool:"bench" ~summary:`Null ~request:(request ~index kilobytes))
    done;
    let lateness = ref [] in
    let loads = ref 0 in
    Eio_main.run (fun env ->
      Eio.Switch.run (fun sw ->
        (match mode with
         | "pool" ->
           Domain_pool_ref.set (Domain_pool.create ~sw ~domain_count:1 (Eio.Stdenv.domain_mgr env))
         | "own" | "idle" -> ()
         | other -> invalid_arg ("bench_original_request_load: unknown mode " ^ other));
        let clock = Eio.Stdenv.clock env in
        let deadline = now () +. seconds in
        let load_in_turn () =
          let index = ref 0 in
          while now () < deadline do
            (match fail_on_error (Owner.load ~store ~scope ~request_id:(request_id !index)) with
             | Some _ -> incr loads
             | None -> failwith "a retained request is missing");
            index := (!index + 1) mod retained_requests;
            Eio.Fiber.yield ()
          done
        in
        let probe () =
          while now () < deadline do
            let started = now () in
            Eio.Time.sleep clock probe_interval_s;
            lateness := ((now () -. started -. probe_interval_s) *. 1000.0) :: !lateness
          done
        in
        Eio.Fiber.both
          (fun () -> if String.equal mode "idle" then () else load_in_turn ())
          probe;
        Domain_pool_ref.clear_for_tests ()));
    let sorted = Array.of_list !lateness in
    Array.sort Float.compare sorted;
    Printf.printf
      "%-4s %5d KB  loads/s %7.1f  probe n=%d p50 %.2f p95 %.2f p99 %.2f max %.1f ms\n"
      mode kilobytes (float_of_int !loads /. seconds) (Array.length sorted)
      (percentile sorted 0.50) (percentile sorted 0.95) (percentile sorted 0.99)
      sorted.(Array.length sorted - 1))
;;
