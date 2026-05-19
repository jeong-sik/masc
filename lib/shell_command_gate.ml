type caller =
  | Worker_dev_tools
  | Tool_code_write
  | Keeper_shell_bash

type cannot_parse_kind =
  | Parse_error
  | Parse_aborted of Masc_exec.Parsed.reason_aborted
  | Too_complex of Masc_exec.Parsed.reason_too_complex
  | Unsupported_nested_pipeline of { stage_index : int }

type shape =
  | Simple
  | Pipeline of { stages : int }

type parsed_context = {
  ast : Masc_exec.Shell_ir.t;
  shape : shape;
  stage_bins : string list;
}

type reject_reason =
  | Command_not_in_allowlist of { bin : string }
  | Pipeline_segment_disallowed of { stage : int; bin : string }
  | Pipes_not_allowed of { stages : int }

type decision =
  | Allow of parsed_context
  | Reject of {
      context : parsed_context;
      reason : reject_reason;
      diagnostic : string;
    }
  | Cannot_parse of { kind : cannot_parse_kind }

(* Walk a Shell_ir.t and return a flat [simple list] if there are no
   nested pipelines, or [Error stage_index] (0-based) for the first
   nested stage encountered.

   The current bash_subset grammar never produces nested pipelines
   (see lib/exec/parser/bash.ml's [to_shell_ir] which maps a list of
   stages directly to [Pipeline (List.map Simple ...)]); but the
   [Shell_ir.t] type allows nesting structurally, so this walker
   is the explicit fail-closed boundary.  RFC-0131 PR-1b replaces
   the prior [List.concat_map] flattener that silently collapsed
   any future nested pipeline into a flat stage list. *)
let safe_simples_of_ir : Masc_exec.Shell_ir.t -> (Masc_exec.Shell_ir.simple list, int) result
  = function
  | Masc_exec.Shell_ir.Simple simple -> Ok [ simple ]
  | Masc_exec.Shell_ir.Pipeline stages ->
    let rec loop idx acc = function
      | [] -> Ok (List.rev acc)
      | Masc_exec.Shell_ir.Simple s :: rest -> loop (idx + 1) (s :: acc) rest
      | Masc_exec.Shell_ir.Pipeline _ :: _ -> Error idx
    in
    loop 0 [] stages
;;

let shape_of_count = function
  | 0 | 1 -> Simple
  | stages -> Pipeline { stages }
;;

let parsed_context_of_shell_ir ast : (parsed_context, cannot_parse_kind) result =
  match safe_simples_of_ir ast with
  | Error stage_index -> Error (Unsupported_nested_pipeline { stage_index })
  | Ok simples ->
    let stage_bins =
      simples
      |> List.map (fun simple -> Masc_exec.Bin.to_string simple.Masc_exec.Shell_ir.bin)
    in
    Ok { ast; shape = shape_of_count (List.length stage_bins); stage_bins }
;;

let parse ?caller:_ cmd =
  (* [caller] is captured for the upcoming telemetry partition
     (RFC-0131 PR-3) and does not affect the parse result.  The
     ignored-argument pattern is intentional: PR-1a establishes the
     API surface; PR-3 wires the counters. *)
  match Masc_exec_bash_parser.Bash.parse_string cmd with
  | Masc_exec.Parsed.Parsed ast -> parsed_context_of_shell_ir ast
  | Masc_exec.Parsed.Parse_error _ -> Error Parse_error
  | Masc_exec.Parsed.Parse_aborted r -> Error (Parse_aborted r)
  | Masc_exec.Parsed.Too_complex r -> Error (Too_complex r)
;;

let stage_count context = List.length context.stage_bins

let last_stage_bin context =
  match List.rev context.stage_bins with
  | [] -> None
  | bin :: _ -> Some bin
;;

let bin_allowed ~allowed_commands bin =
  List.exists (String.equal bin) allowed_commands
;;

let first_disallowed_stage ~allowed_commands context =
  let rec scan stage = function
    | [] -> None
    | bin :: rest ->
      if bin_allowed ~allowed_commands bin then scan (stage + 1) rest else Some (stage, bin)
  in
  scan 1 context.stage_bins
;;

let validate_allowlist ?caller ?(allow_pipes = true) ~allowed_commands cmd =
  match parse ?caller cmd with
  | Error kind -> Cannot_parse { kind }
  | Ok context ->
    let stages = stage_count context in
    if (not allow_pipes) && stages > 1
    then
      Reject
        { context
        ; reason = Pipes_not_allowed { stages }
        ; diagnostic = "pipelines are not allowed for this command surface"
        }
    else (
      match first_disallowed_stage ~allowed_commands context with
      | None -> Allow context
      | Some (stage, bin) ->
        let reason =
          match context.shape with
          | Simple -> Command_not_in_allowlist { bin }
          | Pipeline _ -> Pipeline_segment_disallowed { stage; bin }
        in
        let diagnostic =
          match reason with
          | Command_not_in_allowlist { bin } ->
            Printf.sprintf "%s not in shell command allowlist" bin
          | Pipeline_segment_disallowed { stage; bin } ->
            Printf.sprintf "pipeline stage %d command %s not in shell command allowlist" stage bin
          | Pipes_not_allowed { stages } ->
            Printf.sprintf "pipeline with %d stages is not allowed" stages
        in
        Reject { context; reason; diagnostic })
;;

let caller_tag = function
  | Worker_dev_tools -> "worker_dev_tools"
  | Tool_code_write -> "tool_code_write"
  | Keeper_shell_bash -> "keeper_shell_bash"
;;

let cannot_parse_kind_tag = function
  | Parse_error -> "parse_error"
  | Parse_aborted `Timeout_50ms -> "timeout"
  | Parse_aborted `Depth_limit -> "depth_limit"
  | Parse_aborted `Token_limit_50k -> "token_limit"
  | Unsupported_nested_pipeline _ -> "unsupported_nested_pipeline"
  | Too_complex `Heredoc -> "heredoc"
  | Too_complex `Here_string -> "here_string"
  | Too_complex `Cmd_subst -> "cmd_subst"
  | Too_complex `Proc_subst -> "proc_subst"
  | Too_complex `Subshell -> "subshell"
  | Too_complex `Arith_expansion -> "arith_expansion"
  | Too_complex `Control_flow -> "control_flow"
  | Too_complex `Logic_op -> "logic_op"
  | Too_complex `Function_def -> "function_def"
  | Too_complex `Glob_brace -> "glob_brace"
  | Too_complex `Background -> "background"
  | Too_complex `Redirect -> "redirect"
  | Too_complex (`Unknown_construct _) -> "other"
;;

let reject_reason_tag = function
  | Command_not_in_allowlist _ -> "command"
  | Pipeline_segment_disallowed _ -> "pipeline_segment"
  | Pipes_not_allowed _ -> "pipes_not_allowed"
;;

let decision_tag = function
  | Allow _ -> "allow"
  | Reject _ -> "reject"
  | Cannot_parse _ -> "cannot_parse"
;;
