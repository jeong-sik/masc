(* RFC-0070 Phase 3b-iii — Plan record real impl. See .mli. *)

type plan_error =
  | Invalid_meta of string
  | Invalid_command of string

(* Phase 3b-iii defaults — Phase 3b-iv replaces with caller-provided
   values. Kept as named constants (CLAUDE.md §Magic Number 금지). *)
let default_image = "ubuntu:22.04"
let default_timeout_budget_sec = 30.0
let default_hash_algo = Keeper_hash_algo.SHA_256

type t =
  { container_name : Keeper_container_name.t
  ; image : string
  ; command : string
  ; timeout_budget_sec : float
  }

let of_request ~turn_id ~attempt ~meta_name ~cmd =
  if String.equal meta_name "" then Error (Invalid_meta "meta_name must not be empty")
  else if String.equal cmd "" then Error (Invalid_command "cmd must not be empty")
  else
    let container_name =
      Keeper_container_name.derive
        ~algo:default_hash_algo
        ~turn_id
        ~attempt
        ~suffix:meta_name
    in
    Ok
      { container_name
      ; image = default_image
      ; command = cmd
      ; timeout_budget_sec = default_timeout_budget_sec
      }

let container_name t = t.container_name
let image t = t.image
let command t = t.command
let timeout_budget_sec t = t.timeout_budget_sec

let equal a b =
  Keeper_container_name.equal a.container_name b.container_name
  && String.equal a.image b.image
  && String.equal a.command b.command
  && Float.equal a.timeout_budget_sec b.timeout_budget_sec

let pp ppf t =
  Format.fprintf ppf
    "@[<v 2>Sandbox_plan {@,container_name = %a;@,image = %S;@,command = %S;@,timeout_budget_sec = %g@]@,}"
    Keeper_container_name.pp t.container_name
    t.image t.command t.timeout_budget_sec
