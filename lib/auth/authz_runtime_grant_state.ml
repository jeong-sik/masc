(* HIGH-RISK-UNREVIEWED: see the interface. *)

open Authz_types
open Authz_records
module Grant_map = Map.Make (Grant_id)
module Runtime_map = Map.Make (Runtime_id)

(* The grants by id, and the same grants again under the Runtime they are on.
   The second index is what the design's "(Principal.t * Runtime_id.t)" lookup
   needs (design 4.2-1): one Runtime holds a short list, so answering it is a
   short walk instead of a scan over every grant in the log. *)
type t =
  { grants : Runtime_grant.t Grant_map.t
  ; by_runtime : (Grant_id.t * Runtime_grant.t) list Runtime_map.t
  }

let empty = { grants = Grant_map.empty; by_runtime = Runtime_map.empty }
let find t grant_id = Grant_map.find_opt grant_id t.grants
let mem t grant_id = Grant_map.mem grant_id t.grants

let of_runtime t runtime_id =
  Option.value ~default:[] (Runtime_map.find_opt runtime_id t.by_runtime)
;;

let of_grantee t principal =
  Grant_map.bindings t.grants
  |> List.filter (fun (_, grant) ->
    Principal.equal grant.Runtime_grant.grantee principal)
;;

(* The design lets one (grantee, Runtime) pair hold one live delegate grant
   (design 4.2-1 requires a revoke before a second grant). The state holds what
   the log named, and ids do not sort by time (an id is any safe string), so a
   log that names two is read in the order it named them and the live one is
   answered: the last [Active] grant, and otherwise the last grant, so a caller
   that must explain a refusal sees the record that closed it. *)
let is_active = function
  | Grant_status.Active -> true
  | Grant_status.Revoked -> false
  | Grant_status.Purged -> false
;;

let find_for t ~grantee ~runtime_id =
  let matching =
    of_runtime t runtime_id
    |> List.filter (fun (_, grant) -> Principal.equal grant.Runtime_grant.grantee grantee)
  in
  let latest = List.rev matching in
  match List.find_opt (fun (_, grant) -> is_active grant.Runtime_grant.status) latest with
  | Some (_, grant) -> Some grant
  | None ->
    (match latest with
     | [] -> None
     | (_, grant) :: _ -> Some grant)
;;

type refusal = Already_named of Grant_id.t

let refusal_to_string = function
  | Already_named id ->
    Printf.sprintf "the grant %s was named before" (Grant_id.to_string id)
;;

let add t (grant : Runtime_grant.t) =
  if Grant_map.mem grant.id t.grants
  then Error (Already_named grant.id)
  else (
    let existing =
      Option.value ~default:[] (Runtime_map.find_opt grant.runtime_id t.by_runtime)
    in
    (* Appended, not sorted: the list is the order the log named these grants,
       which is the only order that says which came last. *)
    let by_runtime =
      Runtime_map.add grant.runtime_id (existing @ [ grant.id, grant ]) t.by_runtime
    in
    Ok { grants = Grant_map.add grant.id grant t.grants; by_runtime })
;;
