(* RFC-0070 Phase 3b-iii — Plan record real impl. See .mli. *)

type plan_error =
  | Invalid_meta of string
  | Invalid_command of string list

(* Phase 3b-iii defaults — Phase 3b-iv replaces with caller-provided
   values. Kept as named constants (CLAUDE.md §Magic Number 금지). *)
let default_image = "ubuntu:22.04"
let default_timeout_budget_sec = 30.0
let default_hash_algo = Keeper_hash_algo.SHA_256

type t =
  { container_name : Keeper_container_name.t
  ; image : string
  ; command_argv : string list
  ; timeout_budget_sec : float
  }

let of_request ~turn_id ~attempt ~meta_name ~command_argv =
  (* Error payload = offending value (per .mli contract). Empty-string
     callers see [Invalid_meta ""] / [Invalid_command []]. *)
  if String.equal meta_name "" then Error (Invalid_meta meta_name)
  else if List.is_empty command_argv then Error (Invalid_command command_argv)
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
      ; command_argv
      ; timeout_budget_sec = default_timeout_budget_sec
      }

let container_name t = t.container_name
let image t = t.image
let command_argv t = t.command_argv
let timeout_budget_sec t = t.timeout_budget_sec

let equal a b =
  Keeper_container_name.equal a.container_name b.container_name
  && String.equal a.image b.image
  && List.equal String.equal a.command_argv b.command_argv
  && Float.equal a.timeout_budget_sec b.timeout_budget_sec

let pp ppf t =
  Format.fprintf ppf
    "@[<v 2>Sandbox_plan {@,container_name = %a;@,image = %S;@,command_argv = \
     [%s];@,timeout_budget_sec = %g@]@,}"
    Keeper_container_name.pp t.container_name
    t.image
    (String.concat "; " (List.map Filename.quote t.command_argv))
    t.timeout_budget_sec
