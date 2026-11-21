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
   the log named, so a log that names two is read as the lower id first and the
   higher id last: a caller that must choose takes the last, which is the one
   the log named most recently. *)
let find_for t ~grantee ~runtime_id =
  of_runtime t runtime_id
  |> List.fold_left
       (fun found (_, grant) ->
          if Principal.equal grant.Runtime_grant.grantee grantee then Some grant else found)
       None
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
    let entry = grant.id, grant in
    let existing =
      Option.value ~default:[] (Runtime_map.find_opt grant.runtime_id t.by_runtime)
    in
    let by_runtime =
      Runtime_map.add
        grant.runtime_id
        (List.sort (fun (a, _) (b, _) -> Grant_id.compare a b) (entry :: existing))
        t.by_runtime
    in
    Ok { grants = Grant_map.add grant.id grant t.grants; by_runtime })
;;
