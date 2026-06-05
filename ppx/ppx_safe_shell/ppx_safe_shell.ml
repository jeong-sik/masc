open Ppxlib

let validate_promotable_ir ir =
  match
    Exec_policy.promote_to_safe
      ~allowed_commands:Exec_policy.readonly_allowed_commands
      ir
  with
  | Ok _ -> Ok ()
  | Error br -> Error (Exec_policy.block_reason_to_string br)
;;

let expr_of_bool ~loc value =
  if value then [%expr true] else [%expr false]
;;

let expr_of_arg_meta ~loc (meta : Masc_exec.Shell_ir.arg_meta) =
  let quoted = expr_of_bool ~loc meta.quoted in
  let glob = expr_of_bool ~loc meta.glob in
  let escaped = expr_of_bool ~loc meta.escaped in
  [%expr
    ({ quoted = [%e quoted]; glob = [%e glob]; escaped = [%e escaped] }
     : Masc_exec.Shell_ir.arg_meta)]
;;

let rec expr_of_arg ~loc = function
  | Masc_exec.Shell_ir.Lit (text, meta) ->
    let text = Ast_builder.Default.estring ~loc text in
    let meta = expr_of_arg_meta ~loc meta in
    [%expr Masc_exec.Shell_ir.Lit ([%e text], [%e meta])]
  | Masc_exec.Shell_ir.Var (name, meta) ->
    let name = Ast_builder.Default.estring ~loc name in
    let meta = expr_of_arg_meta ~loc meta in
    [%expr Masc_exec.Shell_ir.Var ([%e name], [%e meta])]
  | Masc_exec.Shell_ir.Concat parts ->
    let parts = Ast_builder.Default.elist ~loc (List.map (expr_of_arg ~loc) parts) in
    [%expr Masc_exec.Shell_ir.Concat [%e parts]]
;;

let expr_of_bin ~loc bin =
  let bin_name =
    Ast_builder.Default.estring ~loc (Masc_exec.Exec_program.to_string bin)
  in
  [%expr
    match Masc_exec.Exec_program.of_string [%e bin_name] with
    | Ok bin -> bin
    | Error (`Unknown name) ->
      invalid_arg ("safe_sh generated unknown executable: " ^ name)]
;;

let expr_of_env_binding ~loc (name, value) =
  let name = Ast_builder.Default.estring ~loc name in
  let value = expr_of_arg ~loc value in
  [%expr [%e name], [%e value]]
;;

let expr_of_simple ~loc (simple : Masc_exec.Shell_ir.simple) =
  match simple.cwd, simple.redirects, simple.sandbox with
  | None, [], Masc_exec.Sandbox_target.Host ->
    let bin = expr_of_bin ~loc simple.bin in
    let args =
      Ast_builder.Default.elist ~loc (List.map (expr_of_arg ~loc) simple.args)
    in
    let env =
      Ast_builder.Default.elist
        ~loc
        (List.map (expr_of_env_binding ~loc) simple.env)
    in
    [%expr
      ({ bin = [%e bin]
       ; args = [%e args]
       ; env = [%e env]
       ; cwd = None
       ; redirects = []
       ; sandbox = Masc_exec.Sandbox_target.host ()
       }
       : Masc_exec.Shell_ir.simple)]
  | _ ->
    Location.raise_errorf
      ~loc
      "safe_sh only preserves host Shell IR without cwd overrides or redirects"
;;

let rec expr_of_ir ~loc = function
  | Masc_exec.Shell_ir.Simple simple ->
    let simple = expr_of_simple ~loc simple in
    [%expr Masc_exec.Shell_ir.Simple [%e simple]]
  | Masc_exec.Shell_ir.Pipeline stages ->
    let stages =
      Ast_builder.Default.elist ~loc (List.map (expr_of_ir ~loc) stages)
    in
    [%expr Masc_exec.Shell_ir.Pipeline [%e stages]]
;;


let expand ~loc ~path:_ (expr : expression) =
  match expr.pexp_desc with
  | Pexp_constant (Pconst_string (cmd_str, _, _)) ->
      let trimmed = String.trim cmd_str in
      (match Exec_policy.parse_string_to_ir ~mode:Exec_policy.Strict trimmed with
       | Ok ir ->
           (match validate_promotable_ir ir with
            | Ok () ->
              let ir_expr = expr_of_ir ~loc ir in
              [%expr
                Exec_policy.promote_to_safe
                  ~allowed_commands:Exec_policy.readonly_allowed_commands
                  [%e ir_expr]]
            | Error reason ->
                Location.raise_errorf ~loc "Compile-time guardrail violation: %s" reason)
       | Error br ->
           let reason = Exec_policy.block_reason_to_string br in
           Location.raise_errorf ~loc "Compile-time shell parsing failed: %s" reason)
  | _ ->
      Location.raise_errorf ~loc "safe_sh extension expects a string literal"

let ext =
  Extension.declare
    "safe_sh"
    Extension.Context.expression
    Ast_pattern.(single_expr_payload __)
    expand
let () = Ppxlib.Driver.register_transformation "safe_sh" ~extensions:[ext]
