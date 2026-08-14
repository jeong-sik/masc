(* RFC-0379 end-to-end fire inside one process: a real listener socket, the
   real locked store, real runner sweeps, and the durable Monitor_fired row
   in the keeper's event-queue file. This is the transport half of the RFC
   §5 live scenario — the same edge a keeper watches across a server
   restart, observed here by closing the listener between two sweeps. *)

open Alcotest
module D = Monitor_domain
module R = Masc.Keeper_monitor_runner
module S = Masc.Keeper_monitor_store

let fresh_base_path () =
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-monitor-runner-test-%d" (Unix.getpid ()))
  in
  (try Unix.mkdir dir 0o700 with
   | Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  dir
;;

let keeper_name = "rondo"

let queue_mentions_monitor_fired ~base_path =
  let keeper_dir =
    Filename.concat (Filename.concat base_path ".masc") "keepers"
    |> fun keepers -> Filename.concat keepers keeper_name
  in
  match Sys.readdir keeper_dir with
  | entries ->
    Array.exists
      (fun entry ->
         String.length entry >= 11
         && String.sub entry 0 11 = "event-queue"
         &&
         let path = Filename.concat keeper_dir entry in
         let ic = open_in_bin path in
         Fun.protect
           ~finally:(fun () -> close_in_noerr ic)
           (fun () ->
              let content = really_input_string ic (in_channel_length ic) in
              (* The durable row is JSON; the closed kind tag is the
                 discriminator the decoder consumes. *)
              let contains needle haystack =
                let n = String.length needle
                and h = String.length haystack in
                let rec loop i =
                  i + n <= h && (String.sub haystack i n = needle || loop (i + 1))
                in
                loop 0
              in
              contains "monitor_fired" content))
      entries
  | exception Sys_error _ -> false
;;

let test_port_down_fire_lands_durably () =
  Eio_main.run
  @@ fun env ->
  let net = env#net in
  let clock = env#clock in
  let base_path = fresh_base_path () in
  let baselines : (string, R.baseline) Hashtbl.t = Hashtbl.create 4 in
  let now = Unix.gettimeofday () in
  (* Phase 1: a live listener; the first sweep only baselines (Reachable). *)
  let port =
    Eio.Switch.run
    @@ fun listener_sw ->
    let listening =
      Eio.Net.listen
        ~sw:listener_sw
        ~backlog:1
        ~reuse_addr:true
        net
        (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
    in
    let port =
      match Eio.Net.listening_addr listening with
      | `Tcp (_, port) -> port
      | `Unix _ -> fail "expected a tcp listening address"
    in
    S.create
      ~base_path
      { D.id = "mon-restart-probe"
      ; keeper = keeper_name
      ; trigger = D.Port_down { host = "127.0.0.1"; port }
      ; payload = `String "the watched server went down; start verification"
      ; expires_at = now +. 3_600.0
      ; max_fires = 1
      ; fired_count = 0
      ; created_at = now
      ; last_observation = None
      }
    |> (function
     | Ok () -> ()
     | Error message -> fail message);
    R.sweep ~net ~clock ~base_path ~baselines ~now;
    check bool "baseline sweep must not fire" false
      (queue_mentions_monitor_fired ~base_path);
    check int "store still holds the monitor" 1
      (List.length
         (match S.load ~base_path with
          | Ok records -> records
          | Error message -> fail message));
    port
  in
  (* Phase 2: the listener is gone; the next due sweep observes the edge. *)
  ignore (port : int);
  R.sweep ~net ~clock ~base_path ~baselines ~now:(now +. 30.0);
  check bool "the durable Monitor_fired row landed" true
    (queue_mentions_monitor_fired ~base_path);
  check int "the one-shot record was consumed" 0
    (List.length
       (match S.load ~base_path with
        | Ok records -> records
        | Error message -> fail message))
;;

let () =
  run
    "keeper monitor runner fire"
    [ ( "fire"
      , [ test_case
            "port_down edge lands a durable wake"
            `Quick
            test_port_down_fire_lands_durably
        ] )
    ]
