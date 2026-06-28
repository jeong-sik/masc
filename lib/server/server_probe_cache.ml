module Make (C : sig
  type value

  val ttl_sec : float
end) = struct
  let cache : (string, C.value * float) Hashtbl.t = Hashtbl.create 4

  let in_flight : (string, unit) Hashtbl.t = Hashtbl.create 4

  let mu = Stdlib.Mutex.create ()

  let probe_hook_for_tests : (string -> C.value) option Atomic.t =
    Atomic.make None

  let with_lock f = Stdlib.Mutex.protect mu f

  let cached_lookup dir ~now =
    with_lock (fun () ->
        match Hashtbl.find_opt cache dir with
        | Some (value, ts) when now -. ts <= C.ttl_sec -> Some value
        | _ -> None)

  let cached_any dir =
    with_lock (fun () -> Hashtbl.find_opt cache dir |> Option.map fst)

  let try_begin_refresh dir =
    with_lock (fun () ->
        if Hashtbl.mem in_flight dir then false
        else (
          Hashtbl.replace in_flight dir ();
          true))

  let finish_refresh dir value ~now =
    with_lock (fun () ->
        Hashtbl.replace cache dir (value, now);
        Hashtbl.remove in_flight dir)

  let cancel_refresh dir =
    with_lock (fun () -> Hashtbl.remove in_flight dir)

  let clear_cache_for_tests () =
    with_lock (fun () ->
        Hashtbl.clear cache;
        Hashtbl.clear in_flight)

  let seed_cache_for_tests dir value ~refreshed_at =
    with_lock (fun () ->
        Hashtbl.replace cache dir (value, refreshed_at);
        Hashtbl.remove in_flight dir)

  let set_probe_hook_for_tests hook =
    Atomic.set probe_hook_for_tests (Some hook)

  let clear_probe_hook_for_tests () = Atomic.set probe_hook_for_tests None
end

let eio_switch_fork_unavailable = function
  | Invalid_argument msg ->
    String_util.contains_substring msg "Switch accessed from wrong domain"
    || String_util.contains_substring msg "Switch finished"
  | _ -> false
;;

let background_refresh_unavailable_domains : (int, unit) Hashtbl.t = Hashtbl.create 4
let background_refresh_unavailable_domains_mu = Stdlib.Mutex.create ()

let current_domain_id () = (Domain.self () :> int)

let background_refresh_domain_unavailable () =
  Stdlib.Mutex.lock background_refresh_unavailable_domains_mu;
  Fun.protect
    ~finally:(fun () -> Stdlib.Mutex.unlock background_refresh_unavailable_domains_mu)
    (fun () -> Hashtbl.mem background_refresh_unavailable_domains (current_domain_id ()))
;;

let background_refresh_mark_domain_unavailable () =
  Stdlib.Mutex.lock background_refresh_unavailable_domains_mu;
  Fun.protect
    ~finally:(fun () -> Stdlib.Mutex.unlock background_refresh_unavailable_domains_mu)
    (fun () -> Hashtbl.replace background_refresh_unavailable_domains (current_domain_id ()) ())
;;

let background_refresh_clear_unavailable_domains_for_tests () =
  Stdlib.Mutex.lock background_refresh_unavailable_domains_mu;
  Fun.protect
    ~finally:(fun () -> Stdlib.Mutex.unlock background_refresh_unavailable_domains_mu)
    (fun () -> Hashtbl.clear background_refresh_unavailable_domains)
;;

let fork_background_refresh_or_cancel ~dir ~cancel_refresh run =
  if background_refresh_domain_unavailable ()
  then cancel_refresh dir
  else match Eio_context.get_switch_opt () with
  | None -> cancel_refresh dir
  | Some sw ->
    (try Eio.Fiber.fork ~sw run with
     | exn when eio_switch_fork_unavailable exn ->
       background_refresh_mark_domain_unavailable ();
       cancel_refresh dir
     | exn ->
       cancel_refresh dir;
       raise exn)
;;
