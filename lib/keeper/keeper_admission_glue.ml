(* See keeper_admission_glue.mli for documentation. *)

let flag_cache : bool option ref = ref None

let parse_bool_env raw =
  match String.lowercase_ascii (String.trim raw) with
  | "true" | "1" | "yes" -> true
  | _ -> false

let use_new_admission () =
  match !flag_cache with
  | Some v -> v
  | None ->
      let v =
        match Sys.getenv_opt "MASC_ADMISSION_USE_NEW" with
        | None -> false
        | Some raw -> parse_bool_env raw
      in
      flag_cache := Some v;
      v

type policy_lookup = string -> Keeper_admission_policy.t option

type outcome =
  | New_admission of Keeper_admission_router.decision
  | Legacy_path

let decide ~keeper_id ~policies ~buckets =
  if not (use_new_admission ()) then Legacy_path
  else
    match policies keeper_id with
    | None -> Legacy_path
    | Some policy ->
        let decision = Keeper_admission_router.schedule ~policy ~buckets in
        New_admission decision

(* Shadow-mode decision: compute the router outcome WITHOUT consulting
   [MASC_ADMISSION_USE_NEW] and WITHOUT consuming bucket tokens.

   This exists because RFC-0026 PR-E-1.6 ships in shadow mode by
   default (flag off).  [decide] short-circuits to [Legacy_path] when
   the flag is off, which would defeat the purpose of the
   [metric_keeper_admission_shadow_outcome] counter — we'd only see
   the [legacy] label.  PR-E-1.8 reads the dispatch/wait/surface
   distribution from this counter to decide when to flip the flag,
   so we need real outcomes regardless of flag state.

   Flag still gates whether the result is APPLIED (caller checks
   [decide]).  This function only COMPUTES. *)
let decide_shadow ~keeper_id ~policies ~buckets =
  match policies keeper_id with
  | None -> Legacy_path
  | Some policy ->
      let decision = Keeper_admission_router.schedule_peek ~policy ~buckets in
      New_admission decision
