(* Exec shell gate SSOT — see shell_command_gate.mli for the contract.

   This module accepts pre-parsed Shell IR and applies syntax and redirect
   policies, exposing the result as a closed [verdict] sum
   type. New callers should target this module so shell policy decisions
   share the same parsed context instead of re-deriving command shape
   with caller-local string scanners. *)

module SI = Masc_exec.Shell_ir
module PD = Masc_exec.Parsed
module ST = Masc_exec.Sandbox_target
module BIN = Masc_exec.Exec_program

type reject_reason =
  | Pipes_not_allowed of { stages : int }
  | Redirect_disallowed_in_caller of { stage : int }

type parse_reason =
  | Parse_error
  | Parse_aborted of PD.reason_aborted

type too_complex_reason =
  | Unsupported_nested_pipeline
  | Unsupported_construct of PD.reason_too_complex

type parsed_context = {
  ast : SI.t;
  stages : SI.simple list;
  stage_bins : string list;
}

type verdict =
  | Allow of parsed_context
  | Reject of {
      context : parsed_context;
      reason : reject_reason;
      diagnostic : string;
    }
  | Cannot_parse of { reason : parse_reason }
  | Too_complex of { reason : too_complex_reason }

type syntax_policy = {
  redirect_allowed : bool;
  allow_pipes : bool;
}

type sandbox_context = {
  target : ST.t;
}

let host_sandbox : sandbox_context = { target = ST.host () }

(* Flatten an IR AST into ordered simple stages.

   A non-nested pipeline produced by the bash subset parser has shape
   [Pipeline [Simple _; Simple _; ...]]. A nested pipeline would be
   [Pipeline [Pipeline _; ...]]; the [Nested_pipeline] result keeps
   that case distinguishable from a regular non-nested pipeline. *)
type flatten_result =
  | Flat_simple of SI.simple
  | Flat_pipeline of SI.simple list
  | Nested_pipeline

let flatten_ir : SI.t -> flatten_result = function
  | SI.Simple s -> Flat_simple s
  | SI.Pipeline stages ->
    let nested =
      List.exists
        (function
          | SI.Pipeline _ -> true
          | SI.Simple _ -> false)
        stages
    in
    if nested then Nested_pipeline
    else
      let simples =
        List.map
          (function
            | SI.Simple s -> s
            | SI.Pipeline _ ->
              (* Unreachable: nested check above already excluded
                 pipeline-of-pipeline shapes. [invalid_arg] (not
                 [assert false]) per the convention in
                 keeper_turn_fsm.ml:284 — operators reading a crash
                 dump see *which* caller invariant was violated
                 without cross-referencing line numbers. *)
              invalid_arg
                "Shell_command_gate.flatten_ir: caller invariant — \
                 nested-pipeline pre-check above already excluded \
                 SI.Pipeline from this map but SI.Pipeline reached \
                 the second pass")
          stages
      in
      Flat_pipeline simples
;;

(* Attach a sandbox target to every stage. The Plan calls this
   "echoing the dispatch decision through the IR"; doing it in the
   facade means downstream [Exec_dispatch] consumers do not need a
   separate sandbox argument. *)
let stages_with_sandbox ~(sandbox : sandbox_context) (stages : SI.simple list) =
  List.map (fun (s : SI.simple) -> { s with SI.sandbox = sandbox.target }) stages
;;

let ast_of_stages = function
  | [] -> None
  | [ single ] -> Some (SI.Simple single)
  | many -> Some (SI.Pipeline (List.map (fun s -> SI.Simple s) many))
;;

let make_context ~stages =
  match ast_of_stages stages with
  | None -> None
  | Some ast ->
    let stage_bins = List.map (fun s -> BIN.to_string s.SI.bin) stages in
    Some { ast; stages; stage_bins }
;;

let stage_has_redirect (simple : SI.simple) : bool =
  simple.SI.redirects <> []
;;

let first_redirect_stage stages =
  let rec scan idx = function
    | [] -> None
    | stage :: rest ->
      if stage_has_redirect stage then Some idx else scan (idx + 1) rest
  in
  scan 1 stages
;;

let apply_policy ~(syntax_policy : syntax_policy) ~(sandbox : sandbox_context)
    ~stages : verdict =
  let stages = stages_with_sandbox ~sandbox stages in
  match make_context ~stages with
  | None ->
    (* [make_context] only returns [None] for the empty list, which
       the Bash grammar's separated_nonempty_list cannot produce.
       Defensive — surface as a parse failure rather than a silent
       Allow. *)
    Cannot_parse { reason = Parse_error }
  | Some context ->
    let stage_n = List.length stages in
    if (not syntax_policy.allow_pipes) && stage_n > 1 then
      let diagnostic =
        Printf.sprintf "pipeline with %d stages is not allowed" stage_n
      in
      Reject
        { context
        ; reason = Pipes_not_allowed { stages = stage_n }
        ; diagnostic
        }
    else (
      match first_redirect_stage stages with
      | Some stage when not syntax_policy.redirect_allowed ->
        Reject
          { context
          ; reason = Redirect_disallowed_in_caller { stage }
          ; diagnostic = Printf.sprintf "pipeline stage %d carries a redirect" stage
          }
      | None -> Allow context
      | Some _ -> Allow context)
;;

let parse_only_to_stages (parsed : SI.t PD.t) :
    ( SI.simple list
    , [ `Cannot_parse of parse_reason | `Too_complex of too_complex_reason ] )
    result =
  match parsed with
  | PD.Parse_error _ -> Error (`Cannot_parse Parse_error)
  | PD.Parse_aborted reason -> Error (`Cannot_parse (Parse_aborted reason))
  | PD.Too_complex reason ->
    Error (`Too_complex (Unsupported_construct reason))
  | PD.Parsed ir ->
    (match flatten_ir ir with
     | Flat_simple s -> Ok [ s ]
     | Flat_pipeline stages -> Ok stages
     | Nested_pipeline -> Error (`Too_complex Unsupported_nested_pipeline))
;;

let verdict_tag = function
  | Allow _ -> "allow"
  | Reject _ -> "reject"
  | Cannot_parse _ -> "cannot_parse"
  | Too_complex _ -> "too_complex"
;;

let reject_reason_tag = function
  | Pipes_not_allowed _ -> "pipes_not_allowed"
  | Redirect_disallowed_in_caller _ -> "redirect_disallowed_in_caller"
;;

let parse_reason_tag = function
  | Parse_error -> "parse_error"
  | Parse_aborted `Timeout_50ms -> "timeout"
  | Parse_aborted `Depth_limit -> "depth_limit"
  | Parse_aborted `Token_limit_50k -> "token_limit"
;;

let too_complex_reason_tag = function
  | Unsupported_nested_pipeline -> "unsupported_nested_pipeline"
  | Unsupported_construct `Heredoc -> "heredoc"
  | Unsupported_construct `Here_string -> "here_string"
  | Unsupported_construct `Cmd_subst -> "cmd_subst"
  | Unsupported_construct `Proc_subst -> "proc_subst"
  | Unsupported_construct `Subshell -> "subshell"
  | Unsupported_construct `Arith_expansion -> "arith_expansion"
  | Unsupported_construct `Control_flow -> "control_flow"
  | Unsupported_construct `Logic_op -> "logic_op"
  | Unsupported_construct `Function_def -> "function_def"
  | Unsupported_construct `Glob_brace -> "glob_brace"
  | Unsupported_construct `Background -> "background"
  | Unsupported_construct `Redirect -> "redirect"
  | Unsupported_construct (`Unknown_construct _) -> "unknown_construct"
;;

let log_verdict ~source = function
  | Allow _ -> ()
  | Reject { context; reason; diagnostic } ->
    Logs.warn (fun m ->
      m
        "Shell_command_gate.reject source=%s verdict=%s reason=%s diagnostic=%s stage_bins=%s"
        source
        (verdict_tag (Reject { context; reason; diagnostic }))
        (reject_reason_tag reason)
        diagnostic
        (String.concat "," context.stage_bins))
  | Cannot_parse { reason } ->
    Logs.warn (fun m ->
      m
        "Shell_command_gate.cannot_parse source=%s verdict=%s reason=%s"
        source
        (verdict_tag (Cannot_parse { reason }))
        (parse_reason_tag reason))
  | Too_complex { reason } ->
    Logs.warn (fun m ->
      m
        "Shell_command_gate.too_complex source=%s verdict=%s reason=%s"
        source
        (verdict_tag (Too_complex { reason }))
        (too_complex_reason_tag reason))
;;

let gate_typed ~ir ~syntax_policy ~sandbox () : verdict =
  (* Typed callers have already crossed their schema boundary, so this
     entrypoint intentionally skips raw-string parsing while preserving
     the same policy and verdict surface as [gate_raw]. *)
  let verdict =
    match parse_only_to_stages (PD.Parsed ir) with
    | Error (`Cannot_parse reason) -> Cannot_parse { reason }
    | Error (`Too_complex reason) -> Too_complex { reason }
    | Ok stages -> apply_policy ~syntax_policy ~sandbox ~stages
  in
  log_verdict ~source:"typed" verdict;
  verdict
;;

let gate_raw ~text ~syntax_policy ~sandbox () : verdict =
  let verdict =
    match Masc_exec_bash_parser.Bash.parse_string text with
    | PD.Parsed ir -> gate_typed ~ir ~syntax_policy ~sandbox ()
    | PD.Parse_error _ -> Cannot_parse { reason = Parse_error }
    | PD.Parse_aborted reason -> Cannot_parse { reason = Parse_aborted reason }
    | PD.Too_complex reason ->
      Too_complex { reason = Unsupported_construct reason }
  in
  log_verdict ~source:"raw" verdict;
  verdict
;;

let lower_typed_pipeline ~stages ~sandbox () : verdict =
  let verdict =
    match stages with
    | [] -> Cannot_parse { reason = Parse_error }
    | _ ->
      let stages = stages_with_sandbox ~sandbox stages in
      (match make_context ~stages with
       | None -> Cannot_parse { reason = Parse_error }
       | Some context -> Allow context)
  in
  log_verdict ~source:"typed_pipeline" verdict;
  verdict
;;

let stage_count context = List.length context.stage_bins

let last_stage_bin context =
  match List.rev context.stage_bins with
  | [] -> None
  | bin :: _ -> Some bin
;;

let is_pipeline context = List.length context.stage_bins > 1
