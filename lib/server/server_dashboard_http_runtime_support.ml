type dashboard_compute_mode =
  | Inline_shared
  | Offloaded_readonly

type runtime = {
  net : [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t;
  mono_clock : Eio.Time.Mono.ty Eio.Resource.t;
}

let run_dashboard_compute ?(mode = Offloaded_readonly) ?runtime ~sw ~clock
    ~(config : Workspace.config) ~(kind : Pool_work.kind) ~name compute =
  let _ = runtime, clock in
  let fallback () = compute ~config ~sw in
  let run_in_pool () =
    Eio.Switch.run (fun pool_sw -> `Done (compute ~config ~sw:pool_sw))
  in
  let offloaded () =
    match Executor_pool_ref.get () with
    | None -> fallback ()
    | Some _ ->
      let work =
        match kind with
        | Pool_work.Cpu -> Pool_work.cpu ~name run_in_pool
        | Pool_work.Io -> Pool_work.io ~name run_in_pool
      in
      (match Pool_work.submit work with
       | `Done value -> value)
  in
  match mode with
  | Inline_shared -> fallback ()
  | Offloaded_readonly -> offloaded ()
