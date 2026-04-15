type dashboard_compute_mode =
  | Inline_shared
  | Offloaded_readonly

type runtime = {
  net : [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t;
  mono_clock : Eio.Time.Mono.ty Eio.Resource.t;
}

type t = unit

let create () = ()

let default_state : t = create ()

let default () = default_state

let set_executor_pool pool = Executor_pool_ref.set pool

let run_dashboard_compute state ?(mode = Offloaded_readonly) ?runtime ~sw ~clock
    ~(config : Coord.config) compute =
  let _ = state, runtime, clock in
  let fallback () = compute ~config ~sw in
  let run_in_pool pool_sw =
    `Done (compute ~config ~sw:pool_sw)
  in
  let offloaded () =
    match Executor_pool_ref.get () with
    | Some pool -> (
        try
          match
            Eio.Executor_pool.submit_exn pool ~weight:1.0 (fun () ->
                Eio.Switch.run run_in_pool)
          with
          | `Done value -> value
        with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | exn ->
            Log.Dashboard.warn
              "dashboard offload failed, using inline compute: %s"
              (Printexc.to_string exn);
            fallback ())
    | None -> fallback ()
  in
  match mode with
  | Inline_shared -> fallback ()
  | Offloaded_readonly -> offloaded ()
