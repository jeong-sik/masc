(* Phase 1 SSOT facade — see shell_command_gate.mli for the contract.

   This module deliberately routes every raw command through one
   [Bash.parse_string] call and exposes the result as a closed
   [verdict] sum type. It does not mutate or replace any existing
   path; [Worker_dev_tools] and the lib-root [Shell_command_gate]
   keep their current behavior. New callers should target this
   module so Phase 2..7 of the Plan can retire the duplicate
   string-scanning paths without coordinating across multiple
   surfaces. *)

module SI = Masc_exec.Shell_ir
module PD = Masc_exec.Parsed
module ST = Masc_exec.Sandbox_target
module BIN = Masc_exec.Bin

type caller =
  | Worker_dev_tools
  | Tool_code_write
  | Keeper_shell_bash

type reject_reason =
  | Command_not_in_allowlist of { bin : string }
  | Pipeline_segment_disallowed of { stage : int; bin : string }
  | Pipes_not_allowed of { stages : int }
  | Redirect_disallowed_in_caller of { stage : int }
  | Path_outside_policy of { stage : int; raw_path : string; diagnostic : string }

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

type allowlist_policy = {
  allowed_commands : string list;
  allow_pipes : bool;
  redirect_allowed : bool;
}

type path_policy = {
  classify : (raw_path:string -> [ `Allow | `Deny of string ]) option;
}

type sandbox_context = {
  target : ST.t;
}

let allow_all_paths : path_policy = { classify = None }

let host_sandbox : sandbox_context = { target = ST.host () }

(* Flatten an IR AST into ordered simple stages.

   A non-nested pipeline produced by Bash.parse_string has shape
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

let bin_allowed ~(allowed_commands : string list) (bin : string) =
  List.exists (String.equal bin) allowed_commands
;;

(* Returns the (1-indexed stage, bin) of the first stage whose binary
   name is outside the allowlist, [None] if every stage passes. *)
let first_disallowed_stage ~allowed_commands stage_bins =
  let rec scan idx = function
    | [] -> None
    | bin :: rest ->
      if bin_allowed ~allowed_commands bin then scan (idx + 1) rest
      else Some (idx, bin)
  in
  scan 1 stage_bins
;;

let stage_has_file_redirect (simple : SI.simple) : bool =
  List.exists
    (function
      | Masc_exec.Redirect_scope.File _ -> true
      | Masc_exec.Redirect_scope.Fd_to_fd _ -> false)
    simple.SI.redirects
;;

(* Extract every literal path-bearing surface from a simple stage so
   the path policy can be applied uniformly. [Var] and [Concat] are
   intentionally skipped at Phase 1 — they cannot be statically
   classified without the metadata layer that Plan Phase 5
   introduces. *)
let literal_path_surfaces (simple : SI.simple) : string list =
  let argv =
    List.filter_map
      (function
        | SI.Lit s -> Some s
        | SI.Var _ | SI.Concat _ -> None)
      simple.SI.args
  in
  let redirects =
    List.filter_map
      (function
        | Masc_exec.Redirect_scope.File { target; _ } ->
          Some (Masc_exec.Path_scope.raw target)
        | Masc_exec.Redirect_scope.Fd_to_fd _ -> None)
      simple.SI.redirects
  in
  argv @ redirects
;;

(* Returns the first path-policy failure encountered, [None] if every
   stage's literal path-bearing surface is accepted. Stage index is
   1-based to match the [Pipeline_segment_disallowed] convention. *)
let first_path_failure ~(path_policy : path_policy) stages =
  match path_policy.classify with
  | None -> None
  | Some classify ->
    let rec scan_stages idx = function
      | [] -> None
      | stage :: rest ->
        let rec scan_args = function
          | [] -> None
          | raw :: rest_args ->
            (match classify ~raw_path:raw with
             | `Allow -> scan_args rest_args
             | `Deny diag -> Some (idx, raw, diag))
        in
        (match scan_args (literal_path_surfaces stage) with
         | Some hit -> Some hit
         | None -> scan_stages (idx + 1) rest)
    in
    scan_stages 1 stages
;;

let first_file_redirect_stage stages =
  let rec scan idx = function
    | [] -> None
    | stage :: rest ->
      if stage_has_file_redirect stage then Some idx else scan (idx + 1) rest
  in
  scan 1 stages
;;

let apply_policy ~(allowlist : allowlist_policy) ~(path_policy : path_policy)
    ~(sandbox : sandbox_context) ~stages : verdict =
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
    if (not allowlist.allow_pipes) && stage_n > 1 then
      let diagnostic =
        Printf.sprintf "pipeline with %d stages is not allowed" stage_n
      in
      Reject
        { context
        ; reason = Pipes_not_allowed { stages = stage_n }
        ; diagnostic
        }
    else
      (match
         first_disallowed_stage
           ~allowed_commands:allowlist.allowed_commands
           context.stage_bins
       with
       | Some (stage_idx, bin) ->
         let reason, diagnostic =
           if stage_n = 1 then
             ( Command_not_in_allowlist { bin }
             , Printf.sprintf "%s not in shell command allowlist" bin )
           else
             ( Pipeline_segment_disallowed { stage = stage_idx; bin }
             , Printf.sprintf
                 "pipeline stage %d command %s not in shell command allowlist"
                 stage_idx
                 bin )
         in
         Reject { context; reason; diagnostic }
       | None ->
         (match
            if allowlist.redirect_allowed then None else first_file_redirect_stage stages
          with
          | Some stage ->
            Reject
              { context
              ; reason = Redirect_disallowed_in_caller { stage }
              ; diagnostic =
                  Printf.sprintf "pipeline stage %d carries a file redirect" stage
              }
          | None ->
            (match first_path_failure ~path_policy stages with
             | Some (stage_idx, raw_path, diagnostic) ->
               Reject
                 { context
                 ; reason =
                     Path_outside_policy { stage = stage_idx; raw_path; diagnostic }
                 ; diagnostic
                 }
             | None -> Allow context)))
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

let gate ?caller:_ ~raw ~allowlist ~path_policy ~sandbox () : verdict =
  (* [caller] is captured for the upcoming telemetry partition
     (RFC-0131 PR-3) and does not affect the verdict.  The
     ignored-argument pattern is intentional: this iter establishes
     the API surface; PR-3 wires the counters. *)
  match parse_only_to_stages (Masc_exec_bash_parser.Bash.parse_string raw) with
  | Error (`Cannot_parse reason) -> Cannot_parse { reason }
  | Error (`Too_complex reason) -> Too_complex { reason }
  | Ok stages -> apply_policy ~allowlist ~path_policy ~sandbox ~stages
;;

let gate_typed ?caller:_ ~ir ~allowlist ~path_policy ~sandbox () : verdict =
  (* Typed callers have already crossed their schema boundary, so this
     entrypoint intentionally skips Bash.parse_string while preserving
     the same policy and verdict surface as [gate]. *)
  match parse_only_to_stages (PD.Parsed ir) with
  | Error (`Cannot_parse reason) -> Cannot_parse { reason }
  | Error (`Too_complex reason) -> Too_complex { reason }
  | Ok stages -> apply_policy ~allowlist ~path_policy ~sandbox ~stages
;;

let lower_typed_pipeline ?caller:_ ~stages ~sandbox () : verdict =
  (* See note on [gate] — [caller] is API-shape-only for now. *)
  match stages with
  | [] -> Cannot_parse { reason = Parse_error }
  | _ ->
    let stages = stages_with_sandbox ~sandbox stages in
    (match make_context ~stages with
     | None -> Cannot_parse { reason = Parse_error }
     | Some context -> Allow context)
;;

let caller_tag = function
  | Worker_dev_tools -> "worker_dev_tools"
  | Tool_code_write -> "tool_code_write"
  | Keeper_shell_bash -> "keeper_shell_bash"
;;

let verdict_tag = function
  | Allow _ -> "allow"
  | Reject _ -> "reject"
  | Cannot_parse _ -> "cannot_parse"
  | Too_complex _ -> "too_complex"
;;

let reject_reason_tag = function
  | Command_not_in_allowlist _ -> "command_not_in_allowlist"
  | Pipeline_segment_disallowed _ -> "pipeline_segment_disallowed"
  | Pipes_not_allowed _ -> "pipes_not_allowed"
  | Redirect_disallowed_in_caller _ -> "redirect_disallowed_in_caller"
  | Path_outside_policy _ -> "path_outside_policy"
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

let stage_count context = List.length context.stage_bins

let last_stage_bin context =
  match List.rev context.stage_bins with
  | [] -> None
  | bin :: _ -> Some bin
;;

let is_pipeline context = List.length context.stage_bins > 1

(* RFC-0092 Phase C authority — facade-side predicate.

   This sub-library cannot depend on [masc_mcp.gate_diff_types]
   (which lives in the root masc_mcp library and would introduce a
   cycle), so the env read is duplicated here.  The truthy-value set
   must stay byte-for-byte identical to [Gate_diff_types.
   typed_authority_enabled] — both predicates are the single
   operator-facing SSOT for [MASC_BASH_TYPED_AUTHORITY] and divergence
   would silently break the authority flip.  If a future RFC promotes
   the predicate to a shared dep, delete this copy. *)
let is_authoritative () =
  match Sys.getenv_opt "MASC_BASH_TYPED_AUTHORITY" with
  | Some ("1" | "true" | "TRUE" | "yes" | "on") -> true
  | _ -> false
;;
