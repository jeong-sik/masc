type scope =
  | Inside_worktree of string
  | Inside_sandbox of string
  | Outside_worktree of string
  | Absolute_unknown of string

type t =
  { raw : string
  ; scope : scope
  }

(* A0 skeleton: conservative placeholder.  Real implementation in A1
   wires Tool_code.normalize_path and resolves [..]/symlink escapes. *)
let classify ~raw ~cwd:_ = { raw; scope = Absolute_unknown raw }
let scope t = t.scope
let raw t = t.raw

let pp fmt t =
  let tag =
    match t.scope with
    | Inside_worktree _ -> "inside_worktree"
    | Inside_sandbox _ -> "inside_sandbox"
    | Outside_worktree _ -> "outside_worktree"
    | Absolute_unknown _ -> "absolute_unknown"
  in
  Format.fprintf fmt "%s:%s" tag t.raw
;;
