type installed =
  { cache : Llm_provider.Http_client.cache
  ; domain : Domain.id
  }

let installed : installed option Atomic.t = Atomic.make None

let fresh_connections : unit Eio.Fiber.key = Eio.Fiber.create_key ()

let with_fresh_connections f = Eio.Fiber.with_binding fresh_connections () f

let install ~sw ~mono_clock ~idle_ttl_seconds =
  let cache = Llm_provider.Http_client.create_cache ~sw ~mono_clock ~idle_ttl_seconds () in
  let this_install = Some { cache; domain = Domain.self () } in
  Atomic.set installed this_install;
  (* Compared physically, so a later install is not removed with this one. *)
  Eio.Switch.on_release sw (fun () ->
    ignore (Atomic.compare_and_set installed this_install None : bool))
;;

let for_this_domain () =
  match Atomic.get installed with
  | Some { cache; domain } when domain = Domain.self () ->
    (match Eio.Fiber.get fresh_connections with
     | Some () -> None
     | None -> Some cache)
  | Some _ | None -> None
;;

let stats () =
  Option.map
    (fun { cache; domain = _ } -> Llm_provider.Http_client.cache_stats cache)
    (Atomic.get installed)
;;
