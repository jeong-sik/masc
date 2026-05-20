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
  | Redirect_disallowed_in_caller of { stage_index : int }
      (* RFC-0131 PR-1c.  A stage carries a file redirect (>, >>, <) but
         the caller passed [?redirect_allowed:false].  [stage_index] is
         0-based; for a single-stage command the index is always 0.
         The bash_subset grammar emits structural [File] redirects only
         for the explicit /dev/null sink. General file targets still
         classify as [Too_complex `Redirect]. *)

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

(* Test whether a single [simple] stage carries any [File] redirect
   (>, >>, <).  [Fd_to_fd] redirects (e.g. [2>&1]) are intentionally
   excluded from the policy boundary — they do not touch the file
   system and have no path-policy implication. *)
let stage_has_file_redirect (s : Masc_exec.Shell_ir.simple) : bool =
  List.exists
    (function
      | Masc_exec.Redirect_scope.File _ -> true
      | Masc_exec.Redirect_scope.Fd_to_fd _ -> false)
    s.Masc_exec.Shell_ir.redirects
;;

(* Walk a [Shell_ir.t] looking for the first stage that carries a
   file redirect.  Returns the 0-based stage index, or [None] if no
   file redirects are present.  Nested [Pipeline _] stages are
   skipped here — RFC-0131 PR-1b's [Unsupported_nested_pipeline] is
   the correct rejection point and runs before this scan. *)
let first_file_redirect_stage : Masc_exec.Shell_ir.t -> int option = function
  | Masc_exec.Shell_ir.Simple s -> if stage_has_file_redirect s then Some 0 else None
  | Masc_exec.Shell_ir.Pipeline stages ->
    let rec loop idx = function
      | [] -> None
      | Masc_exec.Shell_ir.Simple s :: rest ->
        if stage_has_file_redirect s then Some idx else loop (idx + 1) rest
      | Masc_exec.Shell_ir.Pipeline _ :: rest -> loop (idx + 1) rest
    in
    loop 0 stages
;;

let validate_parsed_context
      ?(allow_pipes = true)
      ?(redirect_allowed = true)
      ~allowed_commands
      context
  =
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
        | Redirect_disallowed_in_caller { stage_index } ->
          Printf.sprintf "pipeline stage %d carries a file redirect" stage_index
      in
      Reject { context; reason; diagnostic }
    | None when not redirect_allowed ->
      (match first_file_redirect_stage context.ast with
       | Some stage_index ->
         Reject
           { context
           ; reason = Redirect_disallowed_in_caller { stage_index }
           ; diagnostic =
               Printf.sprintf
                 "stage %d carries a file redirect; caller forbids redirects"
                 stage_index
           }
       | None -> Allow context)
    | None -> Allow context)
;;

(* RFC-0131 PR-3 — variant bridge between the facade [caller] sum and
   the [Legendary_counters] partition sum.  Same shape on purpose;
   the legacy facade and Legendary_counters live in the same library
   (no cycle), so the bridge is mechanical and forces an update at
   compile time when either side grows a variant. *)
let legendary_caller_of = function
  | Worker_dev_tools -> Legendary_counters.Worker_dev_tools
  | Tool_code_write -> Legendary_counters.Tool_code_write
  | Keeper_shell_bash -> Legendary_counters.Keeper_shell_bash
;;

let legendary_verdict_kind_of = function
  | Allow _ -> Legendary_counters.Allow
  | Reject _ -> Legendary_counters.Reject
  | Cannot_parse _ -> Legendary_counters.Cannot_parse
;;

let validate_allowlist
      ?caller
      ?(allow_pipes = true)
      ?(redirect_allowed = true)
      ~allowed_commands
      cmd
  =
  let verdict =
    match parse ?caller cmd with
    | Error kind -> Cannot_parse { kind }
    | Ok context ->
      validate_parsed_context ~allow_pipes ~redirect_allowed ~allowed_commands context
  in
  (match caller with
   | Some c ->
     Legendary_counters.incr_shell_gate
       ~caller:(legendary_caller_of c)
       ~verdict:(legendary_verdict_kind_of verdict)
   | None -> ());
  verdict
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
  | Redirect_disallowed_in_caller _ -> "redirect_disallowed_in_caller"
;;

let decision_tag = function
  | Allow _ -> "allow"
  | Reject _ -> "reject"
  | Cannot_parse _ -> "cannot_parse"
;;
