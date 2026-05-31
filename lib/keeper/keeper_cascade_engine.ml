(** Keeper-owned cascade execution boundary. *)

type oas_dispatch_mode = Single_provider_agent_run

type t = {
  engine_id : string;
  oas_dispatch_mode : oas_dispatch_mode;
  allows_oas_internal_cascade : bool;
}

let keeper_managed =
  {
    engine_id = "masc_keeper_named_cascade";
    oas_dispatch_mode = Single_provider_agent_run;
    allows_oas_internal_cascade = false;
  }

let to_string t = t.engine_id

let oas_dispatch_mode t = t.oas_dispatch_mode

let oas_dispatch_mode_to_string = function
  | Single_provider_agent_run -> "single_provider_agent_run"

let allows_oas_internal_cascade t = t.allows_oas_internal_cascade

let guard_keeper_hot_path t =
  match t.oas_dispatch_mode, t.allows_oas_internal_cascade with
  | Single_provider_agent_run, false -> Ok ()
  | Single_provider_agent_run, true ->
      Error
        (Printf.sprintf
           "keeper cascade engine %s must not delegate provider fallback to OAS"
           t.engine_id)

let manifest_fields t =
  [
    ("cascade_engine", `String (to_string t));
    ( "oas_dispatch_mode",
      `String (oas_dispatch_mode_to_string (oas_dispatch_mode t)) );
    ("oas_internal_cascade_allowed", `Bool (allows_oas_internal_cascade t));
  ]
