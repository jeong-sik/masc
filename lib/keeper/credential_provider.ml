(** See {!Credential_provider} interface. *)

type ro_mount = {
  host : string;
  container : string;
}

type binding = {
  identity : string;
  env : (string * string) list;
  ro_mounts : ro_mount list;
  bootstrap : string list option;
  metadata : (string * string) list;
}

type error =
  | Missing_bundle of { identity : string; path : string }
  | Invalid_token of { identity : string; reason : string }
  | Finalize_failed of { identity : string; reason : string }
  | Tear_down_failed of { identity : string; reason : string }

let pp_error = function
  | Missing_bundle { identity; path } ->
      Printf.sprintf "Missing_bundle{identity=%s; path=%s}" identity path
  | Invalid_token { identity; reason } ->
      Printf.sprintf "Invalid_token{identity=%s; reason=%s}" identity reason
  | Finalize_failed { identity; reason } ->
      Printf.sprintf "Finalize_failed{identity=%s; reason=%s}" identity reason
  | Tear_down_failed { identity; reason } ->
      Printf.sprintf "Tear_down_failed{identity=%s; reason=%s}" identity reason

module type S = sig
  val resolve :
    config:Coord.config -> identity:string -> (binding, error) result

  val finalize :
    binding -> container_id:string -> (unit, error) result

  val tear_down : binding -> container_id:string option -> unit
end
