(** Shell_ir_typed — GADT-based typed command IR implementation.

    Coexists with the untyped [Shell_ir.t].  Each constructor records the
    command's input type, output type, risk level, and sandbox requirement
    in the GADT parameters so that policy dispatch can be indexed by the
    compiler.

    Type definitions live in [Shell_ir_typed_types] to break the
    circular dependency with [Shell_ir_typed_walkers_gen] (which
    deconstructs these types in its generated match arms). *)

include Shell_ir_typed_types

(* ---------------------------------------------------------------------- *)
(* of_simple — delegated to generated walker (RFC-0054 PR-4) *)

let of_simple : Shell_ir.simple -> wrapped = Shell_ir_typed_walkers_gen.gen_of_simple

(* ---------------------------------------------------------------------- *)
(* to_simple — delegated to generated walker (RFC-0054 PR-5) *)

let to_simple : type i o r s. (i, o, r, s) command -> Shell_ir.simple =
  Shell_ir_typed_walkers_gen.gen_to_simple
;;

(* ---------------------------------------------------------------------- *)
(* GADT extractors — delegated to generated walkers (RFC-0054 PR-5) *)

let risk = Shell_ir_typed_walkers_gen.gen_risk
let sandbox = Shell_ir_typed_walkers_gen.gen_sandbox

(* ---------------------------------------------------------------------- *)
(* Pretty-printer *)

let pp fmt = function
  | W (Ls { path; flags }) ->
    Format.fprintf
      fmt
      "Ls(path=%a, flags=%d)"
      (Format.pp_print_option Format.pp_print_string)
      path
      (List.length flags)
  | W (Cat { path }) -> Format.fprintf fmt "Cat(path=%s)" path
  | W (Rg { pattern; path; case_sensitive }) ->
    Format.fprintf
      fmt
      "Rg(pattern=%s, path=%a, case_sensitive=%b)"
      pattern
      (Format.pp_print_option Format.pp_print_string)
      path
      case_sensitive
  | W (Git_status { short }) -> Format.fprintf fmt "Git_status(short=%b)" short
  | W (Git_clone { repo; branch; depth }) ->
    Format.fprintf
      fmt
      "Git_clone(repo=%s, branch=%a, depth=%d)"
      repo
      (Format.pp_print_option Format.pp_print_string)
      branch
      depth
  | W (Curl { url; method_; headers; body }) ->
    Format.fprintf
      fmt
      "Curl(url=%s, method=%s, headers=%a, body=%a)"
      url
      (match method_ with
       | `GET -> "GET"
       | `POST -> "POST"
       | `PUT -> "PUT"
       | `DELETE -> "DELETE")
      (Format.pp_print_option (fun fmt hs ->
         List.iter (fun (k, v) -> Format.fprintf fmt "%s:%s " k v) hs))
      headers
      (Format.pp_print_option Format.pp_print_string)
      body
  | W (Rm { paths; recursive; force }) ->
    Format.fprintf
      fmt
      "Rm(paths=%a, recursive=%b, force=%b)"
      (Format.pp_print_list Format.pp_print_string)
      paths
      recursive
      force
  | W (Sudo { target_argv }) ->
    Format.fprintf
      fmt
      "Sudo(target_argv=%a)"
      (Format.pp_print_list
         ~pp_sep:(fun fmt () -> Format.fprintf fmt " ")
         Format.pp_print_string)
      target_argv
  | W (Generic s) -> Format.fprintf fmt "Generic(%a)" Shell_ir.pp (Shell_ir.Simple s)
;;
