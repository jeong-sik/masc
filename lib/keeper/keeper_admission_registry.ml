(* See keeper_admission_registry.mli for documentation. *)

module KAP = Keeper_admission_policy

type t = {
  policies : (string * KAP.t) list;  (* insertion order preserved *)
}

type load_error = {
  keeper_id : string;
  reason : KAP.validation_error;
}

let empty = { policies = [] }

let load_from_json (root : Yojson.Safe.t) : t * load_error list =
  let admission =
    match root with
    | `Assoc fields -> List.assoc_opt "admission" fields
    | _ -> None
  in
  match admission with
  | None -> (empty, [])
  | Some (`Assoc keeper_blocks) ->
      let folded =
        List.fold_left
          (fun (policies, errors) (keeper_id, block_json) ->
            match KAP.parse_admission_json ~keeper_id block_json with
            | Ok policy -> ((keeper_id, policy) :: policies, errors)
            | Error reason ->
                (policies, { keeper_id; reason } :: errors))
          ([], []) keeper_blocks
      in
      let policies, errors = folded in
      ({ policies = List.rev policies }, List.rev errors)
  | Some _ ->
      (* admission key exists but is not an object — surface as a
         single synthetic load_error rather than silently skipping.
         Operators should never see this in production; the
         materializer always lifts a sub-table to an object. *)
      ( empty
      , [ { keeper_id = "<root>"; reason = KAP.Empty_candidate_list } ] )

let lookup t keeper_id =
  match List.assoc_opt keeper_id t.policies with
  | Some p -> Some p
  | None -> None

let keeper_ids t = List.map fst t.policies

let size t = List.length t.policies
