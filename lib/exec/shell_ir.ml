type arg =
  | Lit of string
  | Concat of arg list
  | Var of string

type simple = {
  bin : Bin.t;
  args : arg list;
  env : (string * arg) list;
  cwd : Path_scope.t option;
  redirects : Redirect_scope.t list;
  (* PR-2 root-fix family 3/3 (2026-04-28):
     [sandbox] carries the dispatch decision through the IR so
     [Exec_dispatch.dispatch_simple] can route to host or Docker
     without a separate keeper-only code path. The default
     [Sandbox_target.host ()] preserves the historical behavior; the
     keeper layer overrides it when a Docker runtime is available. *)
  sandbox : Sandbox_target.t;
}

type t =
  | Simple of simple
  | Pipeline of t list

let rec pp_arg fmt = function
  | Lit s -> Format.fprintf fmt "%S" s
  | Var name -> Format.fprintf fmt "$%s" name
  | Concat parts ->
      Format.fprintf fmt "@[<h>";
      List.iter (pp_arg fmt) parts;
      Format.fprintf fmt "@]"

let pp_env fmt (k, v) = Format.fprintf fmt "%s=%a" k pp_arg v

let pp_simple fmt s =
  List.iter (fun e -> pp_env fmt e; Format.pp_print_char fmt ' ') s.env;
  Format.fprintf fmt "%a" Bin.pp s.bin;
  List.iter (fun a -> Format.pp_print_char fmt ' '; pp_arg fmt a) s.args

let rec pp fmt = function
  | Simple s -> pp_simple fmt s
  | Pipeline parts ->
      Format.pp_print_list
        ~pp_sep:(fun fmt () -> Format.fprintf fmt " | ")
        pp fmt parts
