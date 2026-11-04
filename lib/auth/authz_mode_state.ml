(* HIGH-RISK-UNREVIEWED: see the interface. *)

module M = Authz_mode_event
module W = Authz_types.Workspace_id

type t =
  | Not_bootstrapped
  | Multi_account of W.t
  | Off of W.t

let empty = Not_bootstrapped

let equal a b =
  match a, b with
  | Not_bootstrapped, Not_bootstrapped -> true
  | Multi_account a, Multi_account b | Off a, Off b -> W.equal a b
  | Not_bootstrapped, (Multi_account _ | Off _)
  | Multi_account _, (Not_bootstrapped | Off _)
  | Off _, (Not_bootstrapped | Multi_account _) -> false
;;

let workspace = function
  | Not_bootstrapped -> None
  | Multi_account workspace | Off workspace -> Some workspace
;;

let to_string = function
  | Not_bootstrapped -> "not bootstrapped"
  | Multi_account workspace -> "multi-account for " ^ W.to_string workspace
  | Off workspace -> "off for " ^ W.to_string workspace
;;

type refusal =
  | Out_of_order of
      { state : t
      ; event : M.event
      }
  | Workspace_differs of
      { bootstrapped : W.t
      ; named : W.t
      }

let refusal_to_string = function
  | Out_of_order { state; event } ->
    Printf.sprintf "a %s mode event cannot follow %s" (M.event_label event) (to_string state)
  | Workspace_differs { bootstrapped; named } ->
    Printf.sprintf
      "the mode event names workspace %s, and the bootstrap set up %s"
      (W.to_string named)
      (W.to_string bootstrapped)
;;

(* [Off] and [Reactivate] name the workspace of the bootstrap. *)
let same_workspace ~bootstrapped ~named next =
  if W.equal bootstrapped named then Ok next else Error (Workspace_differs { bootstrapped; named })
;;

let apply state ({ M.event; workspace_id } : M.t) =
  let out_of_order () = Error (Out_of_order { state; event }) in
  match state, event with
  | Not_bootstrapped, M.Fresh_bootstrap -> Ok (Multi_account workspace_id)
  | Not_bootstrapped, M.Off -> out_of_order ()
  | Not_bootstrapped, M.Reactivate -> out_of_order ()
  | Multi_account _, M.Fresh_bootstrap -> out_of_order ()
  | Multi_account bootstrapped, M.Off ->
    same_workspace ~bootstrapped ~named:workspace_id (Off bootstrapped)
  | Multi_account _, M.Reactivate -> out_of_order ()
  | Off _, M.Fresh_bootstrap -> out_of_order ()
  | Off _, M.Off -> out_of_order ()
  | Off bootstrapped, M.Reactivate ->
    same_workspace ~bootstrapped ~named:workspace_id (Multi_account bootstrapped)
;;
