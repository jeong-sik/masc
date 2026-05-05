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
