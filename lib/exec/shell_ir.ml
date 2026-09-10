type arg_meta = {
  quoted : bool;
  glob : bool;
  escaped : bool;
}

let default_meta = { quoted = false; glob = false; escaped = false }

(* [Sequence] keeps its first command in a separate field so an empty
   sequence is not representable. Each connector decides from the status of
   whatever ran last, which is how a shell reads [a && b || c]. *)
type connector =
  | And_if
  | Or_if
  | Seq

type arg =
  | Lit of string * arg_meta
  | Concat of arg list
  | Var of string * arg_meta
  | Subst of t
      (** Command substitution: the child is a complete IR — pipes,
          sequences and nested substitutions use the same grammar. The
          child's stdout becomes exactly one argv element of the parent;
          there is no word splitting or glob after it (RFC
          shell-ir-typed-command-substitution §2.1, §2.3). *)

and simple = {
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

and t =
  | Simple of simple
  | Pipeline of t list
  | Sequence of {
      head : t;
      tail : (connector * t) list;
    }

(* Every stage's dispatch target replaced, recursively — including the
   stages a [Subst] child carries, which is what makes a substitution
   inherit its parent's dispatch target (RFC
   shell-ir-typed-command-substitution §2.3 item 1). The IR — not a
   wrapper argument — is what execution reads ({!Exec_dispatch.dispatch}
   has no sandbox parameter), so a caller that wants the same command run
   under a different target must hand execution a rewritten IR. The
   observation stage (RFC-0422) is that caller: it receives the IR the
   keeper built for its effect target and must run it under the box's
   target instead. A [Delegated] stage keeps its own target: it names a
   masc tool call whose routing is the delegation's, not the box's. *)
let rec with_sandbox (target : Sandbox_target.t) (ir : t) : t =
  let rec arg_rewritten = function
    | Subst child -> Subst (with_sandbox target child)
    | Concat parts -> Concat (List.map arg_rewritten parts)
    | (Lit _ | Var _) as leaf -> leaf
  in
  let stage (simple : simple) : simple =
    match simple.sandbox with
    | Sandbox_target.Delegated _ -> simple
    | Sandbox_target.Host
    | Sandbox_target.Docker _
    | Sandbox_target.Micro_vm _
    | Sandbox_target.Ssh _ ->
      { simple with
        sandbox = target
      ; args = List.map arg_rewritten simple.args
      ; env = List.map (fun (k, v) -> k, arg_rewritten v) simple.env
      }
  in
  match ir with
  | Simple simple -> Simple (stage simple)
  | Pipeline stages -> Pipeline (List.map (with_sandbox target) stages)
  | Sequence { head; tail } ->
    Sequence
      { head = with_sandbox target head
      ; tail = List.map (fun (c, ir) -> (c, with_sandbox target ir)) tail
      }
;;

(* A substitution child inherits the parent's dispatch target (above) and,
   when it declares no cwd of its own, the parent's cwd — bash's rule that
   [$(pwd)] answers the parent's directory. The parent's cwd already passed
   the gate's path jail, so an inherited directory stays inside it; leaving
   the child's cwd [None] would instead run it in the dispatcher's default
   directory, which the gate never saw. *)
let rec with_sandbox_cwd
    (target : Sandbox_target.t)
    (parent_cwd : Path_scope.t option)
    (ir : t)
    : t =
  let rec arg_rewritten = function
    | Subst child -> Subst (with_sandbox_cwd target parent_cwd child)
    | Concat parts -> Concat (List.map arg_rewritten parts)
    | (Lit _ | Var _) as leaf -> leaf
  in
  let stage (simple : simple) : simple =
    match simple.sandbox with
    | Sandbox_target.Delegated _ -> simple
    | Sandbox_target.Host
    | Sandbox_target.Docker _
    | Sandbox_target.Micro_vm _
    | Sandbox_target.Ssh _ ->
      { simple with
        sandbox = target
      ; cwd =
          (match simple.cwd with
           | Some _ as declared -> declared
           | None -> parent_cwd)
      ; args = List.map arg_rewritten simple.args
      ; env = List.map (fun (k, v) -> k, arg_rewritten v) simple.env
      }
  in
  match ir with
  | Simple simple -> Simple (stage simple)
  | Pipeline stages -> Pipeline (List.map (with_sandbox_cwd target parent_cwd) stages)
  | Sequence { head; tail } ->
      Sequence
        { head = with_sandbox_cwd target parent_cwd head
        ; tail =
            List.map (fun (c, ir) -> (c, with_sandbox_cwd target parent_cwd ir)) tail
        }
;;

let rec arg_has_variable = function
  | Lit _ -> false
  | Var _ -> true
  | Subst ir -> has_variable_expansion ir
  | Concat parts -> List.exists arg_has_variable parts

and has_variable_expansion = function
  | Simple simple ->
    List.exists arg_has_variable simple.args
    || List.exists (fun (_, arg) -> arg_has_variable arg) simple.env
  | Pipeline stages -> List.exists has_variable_expansion stages
  | Sequence { head; tail } ->
    has_variable_expansion head
    || List.exists (fun (_, stage) -> has_variable_expansion stage) tail
;;

let rec subst_children_of_arg = function
  | Subst child -> [ child ]
  | Concat parts -> List.concat_map subst_children_of_arg parts
  | Lit _ | Var _ -> []
;;

let rec arg_has_substitution = function
  | Subst _ -> true
  | Concat parts -> List.exists arg_has_substitution parts
  | Lit _ | Var _ -> false
;;

let rec has_command_substitution = function
  | Simple simple ->
    List.exists arg_has_substitution simple.args
    || List.exists (fun (_, arg) -> arg_has_substitution arg) simple.env
  | Pipeline stages -> List.exists has_command_substitution stages
  | Sequence { head; tail } ->
    has_command_substitution head
    || List.exists (fun (_, stage) -> has_command_substitution stage) tail
;;

let rec pp_arg fmt = function
  | Lit (s, _) -> Format.fprintf fmt "%S" s
  | Var (name, _) -> Format.fprintf fmt "$%s" name
  | Subst ir -> Format.fprintf fmt "$(%a)" pp ir
  | Concat parts ->
      Format.fprintf fmt "@[<h>";
      List.iter (pp_arg fmt) parts;
      Format.fprintf fmt "@]"

and pp_env fmt (k, v) = Format.fprintf fmt "%s=%a" k pp_arg v

and pp_simple fmt s =
  List.iter (fun e -> pp_env fmt e; Format.pp_print_char fmt ' ') s.env;
  Format.fprintf fmt "%a" Exec_program.pp s.bin;
  List.iter (fun a -> Format.pp_print_char fmt ' '; pp_arg fmt a) s.args

and pp_connector fmt = function
  | And_if -> Format.pp_print_string fmt " && "
  | Or_if -> Format.pp_print_string fmt " || "
  | Seq -> Format.pp_print_string fmt "; "

and pp fmt = function
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
