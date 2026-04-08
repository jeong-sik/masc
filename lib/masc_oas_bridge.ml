(* lib/masc_oas_bridge.ml *)
(** Centralized boundary between MASC subsystems and the OAS Agent SDK.
    Enforces strict structural timeouts, cancellation safety, and type isolation. *)

(** Safe execution of a generic OAS operation.
    Applies timeout handling when an Eio clock is available, and converts
    [Eio.Time.Timeout] into an error result.
    [Eio.Cancel.Cancelled] is always re-raised to preserve structured concurrency. *)
let run_safe ~timeout_s fn =
  let do_timeout fn =
    match (Masc_eio_env.get ()).clock with
    | Some clock -> Eio.Time.with_timeout_exn clock timeout_s fn
    | None -> fn ()
  in
  try
    do_timeout fn
  with
  | Eio.Time.Timeout ->
    Log.Misc.warn "masc_oas_bridge: OAS execution timed out after %.1fs" timeout_s;
    Error (Oas.Error.Api (Timeout { message = Printf.sprintf "Execution timed out after %.1fs" timeout_s }))
  | Eio.Cancel.Cancelled _ as exn ->
    let bt = Printexc.get_raw_backtrace () in
    Log.Misc.warn "masc_oas_bridge: OAS execution cancelled";
    Printexc.raise_with_backtrace exn bt
  | exn ->
    let bt = Printexc.get_backtrace () in
    Log.Misc.error "masc_oas_bridge: OAS execution error: %s\n%s" (Printexc.to_string exn) bt;
    Error (Oas.Error.Internal (Printexc.to_string exn))
