module Shell_gate = Masc_exec_command_gate.Shell_command_gate

type t = {
  shell : string;
  script : string;
}

(* Closed list.  A shell that is not here lowers as an ordinary program, which
   is the same thing that happens today -- being wrong in this direction costs
   an uncounted call, not a changed execution. *)
let shells = [ "sh"; "bash"; "zsh"; "dash"; "ksh" ]

(* [-c], and also the bundled forms a caller reaches for: [-ec], [-lc], [-eu].
   [--] ends option parsing, so a [c] after it is an argument, not a flag. *)
let is_dash_c token =
  String.length token >= 2
  && token.[0] = '-'
  && (not (String.equal token "--"))
  && String.exists (fun c -> c = 'c') (String.sub token 1 (String.length token - 1))
;;

let rec script_after_dash_c = function
  | [] | [ _ ] -> None
  | token :: next :: rest ->
    if String.equal token "--" then None
    else if is_dash_c token then Some next
    else script_after_dash_c (next :: rest)
;;

(* The program as written, path or bare.  [of_argv] stripped the directory
   before asking, and the one other caller did not: a keeper writing
   [/bin/zsh -lc ...] was counted as a call that had left its shell behind.
   Stripping here rather than at each call site is the difference between a
   contract a caller can forget and one it cannot. *)
let names_a_shell program =
  List.exists (String.equal (Filename.basename program)) shells
;;

(* Whether any stage of a lowered IR still invokes a shell.  The tap asks this
   of the dispatch result to say whether the costume came off, so it has to
   look at every stage: rewriting one costume leaves a sibling stage's
   [bash -c] exactly where it was. *)
let rec ir_keeps_a_shell (ir : Masc_exec.Shell_ir.t) =
  match ir with
  | Masc_exec.Shell_ir.Simple simple ->
    names_a_shell (Masc_exec.Exec_program.to_string simple.Masc_exec.Shell_ir.bin)
  | Masc_exec.Shell_ir.Pipeline stages -> List.exists ir_keeps_a_shell stages
  | Masc_exec.Shell_ir.Sequence { head; tail } ->
    ir_keeps_a_shell head || List.exists (fun (_, part) -> ir_keeps_a_shell part) tail
;;

let of_argv = function
  | [] -> None
  | program :: args ->
    let shell = Filename.basename program in
    if not (names_a_shell program) then None
    else (
      match script_after_dash_c args with
      | None -> None
      | Some script -> Some { shell; script })
;;

type finding =
  | Representable
  | Refused_by_policy of string
  | Outside_the_subset of Shell_gate.too_complex_reason
  | Unparsable of Shell_gate.parse_reason

let classify ~syntax_policy ~sandbox { shell = _; script } =
  match Shell_gate.decide_raw ~text:script ~syntax_policy ~sandbox with
  | Shell_gate.Allow _ -> Representable
  | Shell_gate.Reject { diagnostic; _ } -> Refused_by_policy diagnostic
  | Shell_gate.Too_complex { reason } -> Outside_the_subset reason
  | Shell_gate.Cannot_parse { reason } -> Unparsable reason
;;

let finding_tag = function
  | Representable -> "representable"
  | Refused_by_policy _ -> "refused_by_policy"
  | Outside_the_subset reason -> Shell_gate.too_complex_reason_tag reason
  | Unparsable reason -> Shell_gate.parse_reason_tag reason
;;
