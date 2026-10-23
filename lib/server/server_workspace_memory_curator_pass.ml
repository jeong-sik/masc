type domain = Classification | Briefing | Outside_domain
type phase = Discovery | Observer | Successor | Primary
type counts = { mutable calls : int; mutable errors : int; mutable raised : int; mutable cancelled : int }
type pass = { mutex : Stdlib.Mutex.t; id : string; base_path : string; rows : (domain * phase * counts) list }
type context = { pass : pass; domain : domain; phase : phase }
let current : context Eio.Fiber.key = Eio.Fiber.create_key ()
let domains = [Classification; Briefing; Outside_domain]
let phases = [Discovery; Observer; Successor; Primary]
let domain_name = function Classification -> "classification" | Briefing -> "briefing" | Outside_domain -> "outside_domain"
let phase_name = function Discovery -> "discovery" | Observer -> "observer" | Successor -> "successor" | Primary -> "primary"
let calls_metric = Otel_metric_store.declare_histogram "masc_workspace_curator_restore_calls_per_pass"
let failures_metric = Otel_metric_store.declare_histogram "masc_workspace_curator_restore_failures_per_pass"
let publish pass =
  let snapshot = Stdlib.Mutex.protect pass.mutex (fun () ->
    List.map (fun (domain,phase,c) -> domain,phase,{calls=c.calls;errors=c.errors;raised=c.raised;cancelled=c.cancelled}) pass.rows) in
  let rows = List.map (fun (domain,phase,counts) ->
    let labels = ["domain",domain_name domain; "phase",phase_name phase] in
    Otel_metric_store.observe_histogram calls_metric ~labels (float_of_int counts.calls);
    Otel_metric_store.observe_histogram failures_metric ~labels
      (float_of_int (counts.errors + counts.raised + counts.cancelled));
    `Assoc ["domain",`String (domain_name domain);"phase",`String (phase_name phase);
      "calls",`Int counts.calls;"errors",`Int counts.errors;"raised",`Int counts.raised;
      "cancelled",`Int counts.cancelled]) snapshot in
  Log.Server.info "workspace curator pass restores %s" (Yojson.Safe.to_string
    (`Assoc ["pass_id",`String pass.id;"base_path",`String pass.base_path;"restores",`List rows]))
let with_pass ~base_path work =
  let rows = List.concat_map (fun domain -> List.map (fun phase ->
    domain,phase,{calls=0;errors=0;raised=0;cancelled=0}) phases) domains in
  let pass = {mutex=Stdlib.Mutex.create ();id=Random_id.uuid_v7 ();base_path;rows} in
  Eio.Fiber.with_binding current {pass;domain=Outside_domain;phase=Primary} (fun () ->
    Fun.protect ~finally:(fun () -> publish pass) work)
let with_context update work = match Eio.Fiber.get current with
  | None -> work ()
  | Some context -> Eio.Fiber.with_binding current (update context) work
let with_domain domain work = with_context (fun context -> {context with domain}) work
let with_phase phase work = with_context (fun context -> {context with phase}) work
let restore ~run work =
  let context = Eio.Fiber.get current in
  run (fun () -> match context with
  | None -> work ()
  | Some context ->
    let _,_,counts = List.find (fun (domain,phase,_) -> domain=context.domain && phase=context.phase) context.pass.rows in
    let update f = Stdlib.Mutex.protect context.pass.mutex f in
    update (fun () -> counts.calls <- counts.calls + 1);
    match work () with
    | Ok _ as result -> result
    | Error _ as result -> update (fun () -> counts.errors <- counts.errors + 1); result
    | exception exn ->
      let backtrace = Printexc.get_raw_backtrace () in
      update (fun () -> match exn with Eio.Cancel.Cancelled _ -> counts.cancelled <- counts.cancelled + 1
       | _ -> counts.raised <- counts.raised + 1);
      Printexc.raise_with_backtrace exn backtrace)
