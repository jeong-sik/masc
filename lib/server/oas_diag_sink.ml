(* Route OAS [Llm_provider.Diag] diagnostics into MASC's structured log.

   OAS emits provider-boundary diagnostics (e.g. the http_client 4xx
   request-header and request-shape profiles) through [Llm_provider.Diag],
   whose default sink writes to the process stderr. MASC never installed a
   sink, so those signals never reached system_log_*.jsonl and were lost when
   the process stderr was rotated or wiped — a provider 4xx (observed:
   ollama.com deepseek-v4-flash) left no durable record of the request that
   provoked it. See #25148 / #25031.

   The dispatch is written as dependency injection ([route] takes the four
   emitters) so the level-to-emitter mapping and the message formatting are
   testable without capturing global log output. *)

(* Prefix the OAS subsystem [ctx] onto the message so provider diagnostics stay
   attributable once merged into the shared runtime log. *)
let format_line ~ctx message = Printf.sprintf "[oas:%s] %s" ctx message

(* Exhaustive over [Llm_provider.Diag.level] — a new OAS level forces a compile
   update rather than silently dropping to a default emitter. *)
let route ~debug ~info ~warn ~error (level : Llm_provider.Diag.level) ~ctx message
  =
  let emit =
    match level with
    | Llm_provider.Diag.Debug -> debug
    | Llm_provider.Diag.Info -> info
    | Llm_provider.Diag.Warn -> warn
    | Llm_provider.Diag.Error -> error
  in
  emit (format_line ~ctx message)
;;

(* Install the global sink at boot, before any provider call. MASC's own
   [Log.Runtime] level gate then applies (Debug/Info suppressed by default;
   Warn/Error surface); the event is tagged [Boundary] so it stays filterable
   without colliding with keeper events. *)
let install () =
  Llm_provider.Diag.set_sink
    (route
       ~debug:(fun m -> Log.Runtime.debug ~category:Log.Boundary "%s" m)
       ~info:(fun m -> Log.Runtime.info ~category:Log.Boundary "%s" m)
       ~warn:(fun m -> Log.Runtime.warn ~category:Log.Boundary "%s" m)
       ~error:(fun m -> Log.Runtime.error ~category:Log.Boundary "%s" m))
;;
