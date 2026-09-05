(* Typed Execute input projections.

   Static helpers around [Keeper_tool_execute_typed_input] - quote a token for
   policy strings, render its [Argv] or [Script] back to a shell-command
   string (for policy validation + auditing), and pretty-print a validation
   error.

   Extracted from [Keeper_tool_execute_runtime] (godfile decomp). Pure mapping
   over typed input + Stdlib. *)

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

let typed_input_command_text
      ({ source; _ } : Keeper_tool_execute_typed_input.execute_input)
  =
  match source with
  (* The script is already the command line this wants to render. The shell
     that runs it is not part of the line the caller wrote. *)
  | Keeper_tool_execute_typed_input.Script { text; shell = _ } -> text
  | Keeper_tool_execute_typed_input.Argv argv -> typed_stage_command_text argv
;;

(* What an Execute approval is about, in one line: the first line of the
   command the caller wrote, whole. A multi-line script is named by its first
   command; fitting the line into a pane is the renderer's decision. *)
let typed_input_call_summary input =
  String_util.first_nonblank_line (typed_input_command_text input)
;;

(* Execute's callable surface is synchronous: the call holds the Keeper's only
   turn slot until the process ends, so a caller that names no budget is asking
   the Keeper to wait for however long the command happens to take. Nothing
   below this decides otherwise — an absent [timeout_sec] used to mean
   unbounded.

   Measured over 2026-08-20..24 on the reference workspace: 9,396 of 10,331
   Execute calls named no budget, and those held 76% of all Execute wall clock.
   The longest single untimed call ran 29 minutes.

   600s is inside the range callers who do name a budget already use (10s to
   900s), and it is above every legitimate run in that window except one
   [dune test] at 1,077s. A whole test suite is the call that should state its
   own budget, and being stopped is how its author finds that out. *)
let default_timeout_sec = 600.

(* Who set the budget, kept beside the number. A run stopped at a limit its
   caller never chose reads as exit 124, which [Process_eio] documents as
   indistinguishable from a program that exits 124 on its own — so the result
   has to be able to say which limit stopped it. *)
type timeout_budget =
  | Named_by_caller of float
  | Default of float

let timeout_budget_seconds = function
  | Named_by_caller seconds | Default seconds -> seconds
;;

let typed_input_timeout_budget
      ({ timeout_sec; _ } : Keeper_tool_execute_typed_input.execute_input)
  =
  match timeout_sec with
  | Some seconds -> Named_by_caller seconds
  | None -> Default default_timeout_sec
;;

let typed_input_timeout_sec input =
  timeout_budget_seconds (typed_input_timeout_budget input)
;;

let typed_validation_error_text error =
  Format.asprintf "%a" Keeper_tool_execute_typed_input.pp_validation_error error
;;
