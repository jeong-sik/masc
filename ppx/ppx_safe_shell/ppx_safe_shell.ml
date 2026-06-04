open Ppxlib

let rec validate_ir_capabilities = function
  | Masc_exec.Shell_ir.Simple simple ->
      let flags = Typed_capabilities.classify_program_flags simple.bin in
      let bin_name = Masc_exec.Exec_program.to_string simple.bin in
      let is_dev = Exec_policy.is_dev_allowed bin_name in
      if flags.spawn && not is_dev then
        Error ("Command requires subprocess spawn capability but is not in dev allowlist: " ^ bin_name)
      else if flags.network && not is_dev then
        Error ("Command requires network capability but is not in dev allowlist: " ^ bin_name)
      else
        Ok ()
  | Masc_exec.Shell_ir.Pipeline stages ->
      let rec loop = function
        | [] -> Ok ()
        | stage :: rest ->
            (match validate_ir_capabilities stage with
             | Ok () -> loop rest
             | Error _ as err -> err)
      in
      loop stages


let expand ~loc ~path:_ (expr : expression) =
  match expr.pexp_desc with
  | Pexp_constant (Pconst_string (cmd_str, _, _)) ->
      let trimmed = String.trim cmd_str in
      (match Exec_policy.parse_string_to_ir ~mode:Exec_policy.Strict trimmed with
       | Ok ir ->
           let allowed = Exec_policy.dev_allowed_commands in
           (match Exec_policy.validate_command_with_allowlist ~allowed_commands:allowed ir with
            | Ok () ->
                (match validate_ir_capabilities ir with
                 | Ok () ->
                     let loc = expr.pexp_loc in
                     [%expr 
                       Exec_policy.promote_to_safe 
                         ~allowed_commands:Exec_policy.dev_allowed_commands 
                         (Obj.magic () : Masc_exec.Shell_ir.t)
                     ]
                 | Error msg ->
                     Location.raise_errorf ~loc "Compile-time capability violation: %s" msg)
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

