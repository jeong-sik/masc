(* Typed Execute input projections.

   Static helpers around [Keeper_tool_execute_typed_input] - quote a token for
   policy strings, render an [Exec]/[Pipeline] back to a shell-command
   string (for policy validation + auditing), inspect whether env was
   provided, and pretty-print a validation error.

   Extracted from [Keeper_tool_execute_runtime] (godfile decomp). Pure mapping
   over typed input + Stdlib. *)

let has_typed_execute_input_key = function
  | `Assoc fields ->
    List.exists
      (fun (key, _) ->
         String.equal key "argv" || String.equal key "pipeline")
      fields
  | _ -> false
;;

let assoc_upsert key value = function
  | `Assoc fields ->
    `Assoc ((key, value) :: List.filter (fun (k, _) -> not (String.equal k key)) fields)
  | other -> other
;;

let shell_quote_for_policy token =
  let safe_char = function
    | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '_' | '-' | '.' | '/' | ':' | '=' | ',' ->
      true
    | _ -> false
  in
  if String.length token > 0 && String.for_all safe_char token
  then token
  else (
    let parts = String.split_on_char '\'' token in
    "'" ^ String.concat "'\\''" parts ^ "'")
;;

let typed_stage_command_text argv =
  argv |> List.map shell_quote_for_policy |> String.concat " "
;;

let typed_input_command_text = function
  | Keeper_tool_execute_typed_input.Exec { argv; _ } ->
    typed_stage_command_text argv
  | Keeper_tool_execute_typed_input.Pipeline { stages; _ } ->
    stages
    |> List.map (fun (stage : Keeper_tool_execute_typed_input.exec_stage) ->
      typed_stage_command_text stage.argv)
    |> String.concat " | "
;;

let typed_input_has_env = function
  | Keeper_tool_execute_typed_input.Exec { env; _ }
  | Keeper_tool_execute_typed_input.Pipeline { env; _ } ->
    env <> []
;;

let typed_input_timeout_sec = function
  | Keeper_tool_execute_typed_input.Exec { timeout_sec; _ }
  | Keeper_tool_execute_typed_input.Pipeline { timeout_sec; _ } ->
    timeout_sec
;;

let typed_validation_error_text error =
  Format.asprintf "%a" Keeper_tool_execute_typed_input.pp_validation_error error
;;
