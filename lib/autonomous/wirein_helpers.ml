(* Wirein_helpers — pure helpers for the Tier A5 keeper post-turn
   autonomous wire-in. See wirein_helpers.mli for design rationale. *)

let masc_autonomous_enabled () =
  match Sys.getenv_opt "MASC_AUTONOMOUS" with
  | Some ("1" | "true" | "yes" | "on") -> true
  | _ -> false

let upsert_autonomous_meta
    (working_context : Yojson.Safe.t option)
    (autonomous_meta : Yojson.Safe.t) : Yojson.Safe.t option =
  let updated_kv =
    match working_context with
    | None -> [ ("autonomous_meta", autonomous_meta) ]
    | Some (`Assoc kv) ->
        let kv_without =
          List.filter (fun (k, _) -> k <> "autonomous_meta") kv
        in
        ("autonomous_meta", autonomous_meta) :: kv_without
    | Some _ ->
        (* Conservative: working_context shape is not the standard
           [`Assoc kv] map. Rather than silently overwrite an
           unexpected payload, wrap it under the dedicated key so
           downstream consumers see a usable [`Assoc]. *)
        [ ("autonomous_meta", autonomous_meta) ]
  in
  Some (`Assoc updated_kv)
