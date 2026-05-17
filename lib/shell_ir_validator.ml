(* See shell_ir_validator.mli for module rationale. *)

type cannot_parse_kind =
  | Parse_error
  | Parse_aborted of Masc_exec.Parsed.reason_aborted
  | Too_complex of Masc_exec.Parsed.reason_too_complex

type reject_reason =
  | Command_not_in_allowlist of string
  | Pipeline_segment_disallowed of string

type advisory =
  | Allow
  | Reject of { reason : reject_reason; diagnostic : string }
  | Cannot_parse of { kind : cannot_parse_kind }

let advisory_tag = function
  | Allow -> "allow"
  | Reject _ -> "reject"
  | Cannot_parse _ -> "cannot_parse"

let bin_in_allowlist ~allowlist (bin : Masc_exec.Bin.t) : bool =
  let name = Masc_exec.Bin.to_string bin in
  List.exists (String.equal name) allowlist

(* Walks a Masc_exec.Shell_ir.t and returns the first segment whose bin is not in
   the allowlist, [None] when all segments pass.  [Pipeline _] nested
   inside a [Pipeline] is not produced by the current bash_subset
   grammar; the defensive arm degrades to [Cannot_parse Parse_error]
   in [advise] rather than silently allowing. *)
let rec first_disallowed_bin ~allowlist : Masc_exec.Shell_ir.t -> string option = function
  | Masc_exec.Shell_ir.Simple { bin; _ } ->
    if bin_in_allowlist ~allowlist bin then None
    else Some (Masc_exec.Bin.to_string bin)
  | Masc_exec.Shell_ir.Pipeline segments ->
    let rec scan = function
      | [] -> None
      | seg :: rest ->
        (match first_disallowed_bin ~allowlist seg with
         | Some _ as hit -> hit
         | None -> scan rest)
    in
    scan segments

let advise ~cmd ~allowlist : advisory =
  match Masc_exec_bash_parser.Bash.parse_string cmd with
  | Masc_exec.Parsed.Parse_error _ -> Cannot_parse { kind = Parse_error }
  | Masc_exec.Parsed.Parse_aborted r -> Cannot_parse { kind = Parse_aborted r }
  | Masc_exec.Parsed.Too_complex r -> Cannot_parse { kind = Too_complex r }
  | Masc_exec.Parsed.Parsed (Masc_exec.Shell_ir.Simple _ as ast) ->
    (match first_disallowed_bin ~allowlist ast with
     | None -> Allow
     | Some name ->
       Reject
         { reason = Command_not_in_allowlist name
         ; diagnostic = Printf.sprintf "%s not in keeper allowlist" name
         })
  | Masc_exec.Parsed.Parsed (Masc_exec.Shell_ir.Pipeline _ as ast) ->
    (match first_disallowed_bin ~allowlist ast with
     | None -> Allow
     | Some name ->
       Reject
         { reason = Pipeline_segment_disallowed name
         ; diagnostic =
             Printf.sprintf "pipeline segment %s not in keeper allowlist" name
         })
