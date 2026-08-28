type arg_meta = {
  quoted : bool;
  glob : bool;
  escaped : bool;
}

let default_meta = { quoted = false; glob = false; escaped = false }

type arg =
  | Lit of string * arg_meta
  | Concat of arg list
  | Var of string * arg_meta

type simple = {
  bin : Exec_program.t;
  args : arg list;
  env : (string * arg) list;
  cwd : Path_scope.t option;
  redirects : Redirect_scope.t list;
  (* PR-2 root-fix family 3/3 (2026-04-28):
     [sandbox] carries the dispatch decision through the IR so
     [Exec_dispatch.dispatch_simple] can route to host, Docker, or SSH
     without a separate keeper-only code path. The default
     [Sandbox_target.host ()] preserves the historical behavior; the
     keeper layer overrides it when a Docker or SSH runtime is available. *)
  sandbox : Sandbox_target.t;
}

(* [Sequence] keeps its first command in a separate field so an empty
   sequence is not representable. Each connector decides from the status of
   whatever ran last, which is how a shell reads [a && b || c]. *)
type connector =
  | And_if
  | Or_if
  | Seq

type t =
  | Simple of simple
  | Pipeline of t list
  | Sequence of {
      head : t;
      tail : (connector * t) list;
    }

let rec pp_arg fmt = function
  | Lit (s, _) -> Format.fprintf fmt "%S" s
  | Var (name, _) -> Format.fprintf fmt "$%s" name
  | Concat parts ->
      Format.fprintf fmt "@[<h>";
      List.iter (pp_arg fmt) parts;
      Format.fprintf fmt "@]"

let pp_env fmt (k, v) = Format.fprintf fmt "%s=%a" k pp_arg v

let pp_simple fmt s =
  List.iter (fun e -> pp_env fmt e; Format.pp_print_char fmt ' ') s.env;
  Format.fprintf fmt "%a" Exec_program.pp s.bin;
  List.iter (fun a -> Format.pp_print_char fmt ' '; pp_arg fmt a) s.args

let pp_connector fmt = function
  | And_if -> Format.pp_print_string fmt " && "
  | Or_if -> Format.pp_print_string fmt " || "
  | Seq -> Format.pp_print_string fmt "; "

let rec pp fmt = function
  | Simple s -> pp_simple fmt s
  | Pipeline parts ->
      Format.pp_print_list
        ~pp_sep:(fun fmt () -> Format.fprintf fmt " | ")
        pp fmt parts
  | Sequence { head; tail } ->
      pp fmt head;
      List.iter
        (fun (connector, part) ->
          pp_connector fmt connector;
          pp fmt part)
        tail
