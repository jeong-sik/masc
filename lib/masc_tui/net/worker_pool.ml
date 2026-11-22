type t = { pool : Domain_pool.t }

let create ~sw domain_mgr =
  Eio.Switch.check sw;
  { pool = Domains.start_worker_pool ~sw domain_mgr }

let of_domain_pool pool = { pool }

let domain_count t = Domain_pool.domain_count t.pool

let submit_cpu t ~name work = Domain_pool.submit_cpu ~name t.pool work

let submit_cpu_async t ~sw ~name work =
  Eio.Switch.check sw;
  Domain_pool.submit_cpu_async ~sw ~name t.pool work

let submit_result_async t ~sw ~name work =
  Eio.Switch.check sw;
  let promise, resolve = Eio.Promise.create () in
  let resolve_once v = ignore (Eio.Promise.try_resolve resolve v : bool) in
  let raw =
    Domain_pool.submit_cpu_async ~sw ~name t.pool (fun () ->
        match work () with
        | res -> res
        | exception (Eio.Cancel.Cancelled _ as cancelled) -> raise cancelled
        | exception ex -> Error (Printexc.to_string ex))
  in
  Eio.Fiber.fork ~sw (fun () ->
      match Eio.Promise.await raw with
      | Ok res -> resolve_once res
      | Error (Eio.Cancel.Cancelled _ as cancelled) -> (
          resolve_once (Error "cancelled");
          match Eio.Switch.check sw with
          | () -> ()
          | exception (Eio.Cancel.Cancelled _) -> raise cancelled)
      | Error ex -> resolve_once (Error (Printexc.to_string ex))
      | exception (Eio.Cancel.Cancelled _ as cancelled) ->
          resolve_once (Error "cancelled");
          raise cancelled);
  promise
