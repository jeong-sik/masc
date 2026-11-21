(* HIGH-RISK-UNREVIEWED: see the interface. *)

open Authz_types
open Authz_records
module Grant_map = Map.Make (Grant_id)

type t = Runtime_grant.t Grant_map.t

let empty = Grant_map.empty
let find t grant_id = Grant_map.find_opt grant_id t
let mem t grant_id = Grant_map.mem grant_id t

let of_runtime t runtime_id =
  Grant_map.bindings t
  |> List.filter (fun (_, grant) -> Runtime_id.equal grant.Runtime_grant.runtime_id runtime_id)
;;

let of_grantee t principal =
  Grant_map.bindings t
  |> List.filter (fun (_, grant) -> Principal.equal grant.Runtime_grant.grantee principal)
;;

type refusal = Already_named of Grant_id.t

let refusal_to_string = function
  | Already_named id ->
    Printf.sprintf "the grant %s was named before" (Grant_id.to_string id)
;;

let add t (grant : Runtime_grant.t) =
  if Grant_map.mem grant.id t
  then Error (Already_named grant.id)
  else Ok (Grant_map.add grant.id grant t)
;;
