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
(* The gate walks the IR rather than flattening it, because the shape decides
   which rule applies: the pipe rule belongs to a [Pipeline] node and to
   nothing else. Flattening to a list of stages loses that -- [a && b] would
   be counted as two pipeline stages. *)
let rec with_sandbox ~(sandbox : sandbox_context) (ir : SI.t) : SI.t =
  match ir with
  | SI.Simple s -> SI.Simple { s with SI.sandbox = sandbox.target }
  | SI.Pipeline stages -> SI.Pipeline (List.map (with_sandbox ~sandbox) stages)
  | SI.Sequence { head; tail } ->
    SI.Sequence
      { head = with_sandbox ~sandbox head
      ; tail = List.map (fun (connector, part) -> connector, with_sandbox ~sandbox part) tail
      }
;;

let rec simples_of (ir : SI.t) : SI.simple list =
  match ir with
  | SI.Simple s -> [ s ]
  | SI.Pipeline stages -> List.concat_map simples_of stages
  | SI.Sequence { head; tail } ->
    simples_of head @ List.concat_map (fun (_connector, part) -> simples_of part) tail
;;

(* Rules are attached to the shape that carries them: the pipe rule to a
   [Pipeline] node, the redirect rule to any command that names one. Walking
   the IR means a sequence's commands are each checked on their own terms,
   and a nested shape is reached rather than declared unreachable. *)
let stage_has_redirect (simple : SI.simple) : bool = simple.SI.redirects <> []

let first_redirect_stage stages =
  let rec scan idx = function
    | [] -> None
    | stage :: rest -> if stage_has_redirect stage then Some idx else scan (idx + 1) rest
  in
  scan 1 stages
;;

type syntax_violation =
  | Pipes of int
  | Redirect of int

let rec check_syntax ~(syntax_policy : syntax_policy) (ir : SI.t) =
  match ir with
  | SI.Simple s ->
    if stage_has_redirect s && not syntax_policy.redirect_allowed
    then Error (Redirect 1)
    else Ok ()
  | SI.Pipeline stages ->
    let stage_n = List.length stages in
    if not syntax_policy.allow_pipes
    then Error (Pipes stage_n)
    else (
      match first_redirect_stage (List.concat_map simples_of stages) with
      | Some stage when not syntax_policy.redirect_allowed -> Error (Redirect stage)
      | Some _ | None ->
        List.fold_left
          (fun acc part -> Result.bind acc (fun () -> check_syntax ~syntax_policy part))
          (Ok ())
          stages)
  | SI.Sequence { head; tail } ->
    List.fold_left
      (fun acc part -> Result.bind acc (fun () -> check_syntax ~syntax_policy part))
      (check_syntax ~syntax_policy head)
      (List.map snd tail)
;;

let apply_policy ~(syntax_policy : syntax_policy) ~(sandbox : sandbox_context) ~ir : verdict =
  let ir = with_sandbox ~sandbox ir in
  let stages = simples_of ir in
  match stages with
  | [] ->
    (* The Bash grammar's separated_nonempty_list cannot produce an empty
       command; surface it as a parse failure rather than a silent Allow. *)
    Cannot_parse { reason = Parse_error }
  | _ :: _ ->
    let context =
      { ast = ir; stages; stage_bins = List.map (fun s -> BIN.to_string s.SI.bin) stages }
    in
    (match check_syntax ~syntax_policy ir with
     | Ok () -> Allow context
     | Error (Pipes stage_n) ->
       Reject
         { context
         ; reason = Pipes_not_allowed { stages = stage_n }
         ; diagnostic = Printf.sprintf "pipeline with %d stages is not allowed" stage_n
         }
     | Error (Redirect stage) ->
       Reject
         { context
         ; reason = Redirect_disallowed_in_caller { stage }
         ; diagnostic = Printf.sprintf "pipeline stage %d carries a redirect" stage
         })
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
  | Unsupported_construct `Param_expansion -> "param_expansion"
  | Unsupported_construct `Control_flow -> "control_flow"
  | Unsupported_construct `Function_def -> "function_def"
  | Unsupported_construct `Glob_brace -> "glob_brace"
  | Unsupported_construct `Background -> "background"
  | Unsupported_construct `Redirect -> "redirect"
  | Unsupported_construct (`Unknown_construct _) -> "unknown_construct"
;;

let log_verdict ~source = function
  | Allow _ -> ()
  | Reject { context; reason; diagnostic } ->
    Log.Gate.warn
      "Shell_command_gate.reject source=%s verdict=%s reason=%s diagnostic=%s stage_bins=%s"
      source
      (verdict_tag (Reject { context; reason; diagnostic }))
      (reject_reason_tag reason)
      diagnostic
      (String.concat "," context.stage_bins)
  | Cannot_parse { reason } ->
    Log.Gate.warn
      "Shell_command_gate.cannot_parse source=%s verdict=%s reason=%s"
      source
      (verdict_tag (Cannot_parse { reason }))
      (parse_reason_tag reason)
  | Too_complex { reason } ->
    Log.Gate.warn
      "Shell_command_gate.too_complex source=%s verdict=%s reason=%s"
      source
      (verdict_tag (Too_complex { reason }))
      (too_complex_reason_tag reason)
;;

(* The verdict with no logging. [gate_raw] reaches the policy through here
   rather than through [gate_typed], so one call reports one source. *)
(* [SI.Pipeline] carries [t list], so a typed caller can hand [gate_typed] a
   pipeline whose stages are themselves pipelines, or one with fewer than the
   two stages its own documentation requires.  [lower_typed_pipeline] cannot:
   its input is a [simple list], so the invariant holds there by construction.
   [Unsupported_nested_pipeline] was written for exactly the shape only this
   entry point can produce, and nothing produced it -- a nested pipeline
   reached dispatch and ran. *)
let rec structural_refusal (ir : SI.t) =
  match ir with
  | SI.Simple _ -> None
  | SI.Pipeline stages ->
    if List.exists (function SI.Pipeline _ -> true | _ -> false) stages
    then Some (`Too_complex Unsupported_nested_pipeline)
    else if List.compare_length_with stages 2 < 0
    then Some (`Cannot_parse Parse_error)
    else List.find_map structural_refusal stages
  | SI.Sequence { head; tail } ->
    (match structural_refusal head with
     | Some refusal -> Some refusal
     | None -> List.find_map (fun (_, part) -> structural_refusal part) tail)
;;

(* [parse_only_to_ir (PD.Parsed ir)] used to stand where the structural check
   is now.  It always answered [Ok]: the value it inspected is the one this
   function had just wrapped, so its other arms were unreachable and the call
   was an identity wearing the shape of a check. *)
let decide_typed ~ir ~syntax_policy ~sandbox =
  match structural_refusal ir with
  | Some (`Too_complex reason) -> Too_complex { reason }
  | Some (`Cannot_parse reason) -> Cannot_parse { reason }
  | None -> apply_policy ~syntax_policy ~sandbox ~ir
;;

let gate_typed ~ir ~syntax_policy ~sandbox () : verdict =
  (* Typed callers have already crossed their schema boundary, so this
     entrypoint intentionally skips raw-string parsing while preserving
     the same policy and verdict surface as [gate_raw]. *)
  let verdict = decide_typed ~ir ~syntax_policy ~sandbox in
  log_verdict ~source:"typed" verdict;
  verdict
;;

(* The verdict with no logging, so a caller that is only classifying -- not
   about to run the text -- does not add a line indistinguishable from a real
   raw call.  [gate_raw] is this plus the log. *)
let decide_raw ~text ~syntax_policy ~sandbox : verdict =
  match Masc_exec_bash_parser.Bash.parse_string text with
  | PD.Parsed ir -> decide_typed ~ir ~syntax_policy ~sandbox
  | PD.Parse_error _ -> Cannot_parse { reason = Parse_error }
  | PD.Parse_aborted reason -> Cannot_parse { reason = Parse_aborted reason }
  | PD.Too_complex reason -> Too_complex { reason = Unsupported_construct reason }
;;

let gate_raw ~text ~syntax_policy ~sandbox () : verdict =
  let verdict = decide_raw ~text ~syntax_policy ~sandbox in
  log_verdict ~source:"raw" verdict;
  verdict
;;

let lower_typed_pipeline ~stages ~sandbox () : verdict =
  let verdict =
    match stages with
    | [] -> Cannot_parse { reason = Parse_error }
    | [ single ] ->
      let ir = with_sandbox ~sandbox (SI.Simple single) in
      Allow
        { ast = ir
        ; stages = simples_of ir
        ; stage_bins = List.map (fun s -> BIN.to_string s.SI.bin) (simples_of ir)
        }
    | many ->
      let ir = with_sandbox ~sandbox (SI.Pipeline (List.map (fun s -> SI.Simple s) many)) in
      Allow
        { ast = ir
        ; stages = simples_of ir
        ; stage_bins = List.map (fun s -> BIN.to_string s.SI.bin) (simples_of ir)
        }
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
