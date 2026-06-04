open Ppxlib

let expand ~loc ~path:_ (expr : expression) =
  match expr.pexp_desc with
  | Pexp_constant (Pconst_string (cmd_str, _, _)) ->
      let trimmed = String.trim cmd_str in
      (match Exec_policy.parse_string_to_ir ~mode:Exec_policy.Strict trimmed with
       | Ok ir ->
           let allowed = Exec_policy.dev_allowed_commands in
           (match Exec_policy.validate_command_with_allowlist ~allowed_commands:allowed ir with
            | Ok () ->
                (* Statically rewrite to safe promotion signature *)
                let loc = expr.pexp_loc in
                [%expr 
                  Exec_policy.promote_to_safe 
                    ~allowed_commands:Exec_policy.dev_allowed_commands 
                    (Obj.magic () : Masc_exec.Shell_ir.t)
                ]
            | Error br ->
                let reason = Exec_policy.block_reason_to_string br in
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
