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
  | W (Find { path; name; type_ }) ->
    Format.fprintf
      fmt
      "Find(path=%s, name=%a, type_=%a)"
      path
      (Format.pp_print_option Format.pp_print_string)
      name
      (Format.pp_print_option (fun fmt t ->
         Format.pp_print_string fmt (match t with `File -> "f" | `Dir -> "d")))
      type_
  | W (Head { path; lines }) ->
    Format.fprintf fmt "Head(path=%s, lines=%d)" path lines
  | W (Tail { path; lines }) ->
    Format.fprintf fmt "Tail(path=%s, lines=%d)" path lines
  | W (Grep { pattern; path; recursive; case_sensitive }) ->
    Format.fprintf
      fmt
      "Grep(pattern=%s, path=%a, recursive=%b, case_sensitive=%b)"
      pattern
      (Format.pp_print_option Format.pp_print_string)
      path
      recursive
      case_sensitive
  | W (Mkdir { path; parents }) ->
    Format.fprintf fmt "Mkdir(path=%s, parents=%b)" path parents
  | W (Wc { path; mode }) ->
    Format.fprintf
      fmt
      "Wc(path=%s, mode=%s)"
      path
      (match mode with `Lines -> "lines" | `Words -> "words" | `Chars -> "chars")
  | W (Git_diff { stat; cached; paths }) ->
    Format.fprintf
      fmt
      "Git_diff(stat=%b, cached=%b, paths=%a)"
      stat
      cached
      (Format.pp_print_list Format.pp_print_string)
      paths
  | W (Git_log { oneline; max_count }) ->
    Format.fprintf
      fmt
      "Git_log(oneline=%b, max_count=%a)"
      oneline
      (Format.pp_print_option Format.pp_print_int)
      max_count
  | W (Git_commit { message; amend }) ->
    Format.fprintf fmt "Git_commit(message=%s, amend=%b)" message amend
  | W (Git_push { force; force_with_lease; set_upstream; remote; branch }) ->
    Format.fprintf
      fmt
      "Git_push(force=%b, force_with_lease=%b, set_upstream=%b, remote=%a, branch=%a)"
      force
      force_with_lease
      set_upstream
      (Format.pp_print_option Format.pp_print_string)
      remote
      (Format.pp_print_option Format.pp_print_string)
      branch
  | W (Git_pull { rebase; remote; branch }) ->
    Format.fprintf
      fmt
      "Git_pull(rebase=%b, remote=%a, branch=%a)"
      rebase
      (Format.pp_print_option Format.pp_print_string)
      remote
      (Format.pp_print_option Format.pp_print_string)
      branch
  | W (Generic s) -> Format.fprintf fmt "Generic(%a)" Shell_ir.pp (Shell_ir.Simple s)
;;
