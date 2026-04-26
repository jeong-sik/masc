type t =
  | Read_path of Path_scope.t
  | Write_path of Path_scope.t * Redirect_scope.mode
  | Exec_bin of Bin.t * Shell_ir.arg list
  | Git of Git_op.t
  | Env_set of string * Shell_ir.arg
  | Pipeline_fold of t list

let rec pp fmt = function
  | Read_path p -> Format.fprintf fmt "read(%a)" Path_scope.pp p
  | Write_path (p, mode) ->
    let op =
      match mode with
      | Redirect_scope.Read -> "R"
      | Redirect_scope.Write -> "W"
      | Redirect_scope.Append -> "A"
    in
    Format.fprintf fmt "write[%s](%a)" op Path_scope.pp p
  | Exec_bin (b, args) -> Format.fprintf fmt "exec(%a,%d)" Bin.pp b (List.length args)
  | Git op -> Format.fprintf fmt "%a" Git_op.pp op
  | Env_set (k, _) -> Format.fprintf fmt "env(%s)" k
  | Pipeline_fold parts ->
    Format.fprintf fmt "pipeline[%d]" (List.length parts);
    List.iter (fun c -> Format.fprintf fmt " %a" pp c) parts
;;
