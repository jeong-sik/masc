(* RFC-0208 action-flag risk regression guard.

   find/sed/sort are on the readonly + dev command allowlists as read
   tools, but a single flag turns them destructive (find -delete/-exec) or
   write-capable (find -fprintf, sed -i, sort -o) while the command identity
   stays "allowlisted read". The keeper authorizes via the risk-envelope
   pre-gate (keeper_tool_execute_runtime: is_destructive blocks all keepers;
   is_r1/is_r2 blocks a non-write-enabled readonly keeper), so a
   misclassification to R0_Read let a readonly keeper delete and modify
   files past the gate.

   These assertions pin the risk_class the pre-gate keys on. They cover the
   string-parsed path and the typed-input path (the IR built directly from
   {bin; args}, no Bash) — the latter is what a parser-only fix would miss,
   and it is the only reachable path for find -exec (the bash parser rejects
   the `;`/`{}` form as too_complex). *)
open Masc_exec
module Risk = Shell_ir_risk

let envelope ir = Risk.classify (Risk.undecided ir)
let risk_of ir = (envelope ir).Risk.risk

let parse cmd =
  match Masc_exec_bash_parser.Bash.parse_string cmd with
  | Parsed.Parsed ir -> ir
  | _ -> failwith (Printf.sprintf "parse failed/too_complex: %s" cmd)
;;

let lit s = Shell_ir.Lit (s, Shell_ir.default_meta)

let typed_simple bin args =
  Shell_ir.Simple
    { Shell_ir.bin = Result.get_ok (Exec_program.of_string bin)
    ; args = List.map lit args
    ; env = []
    ; cwd = None
    ; redirects = []
    ; sandbox = Sandbox_target.host ()
    }
;;

let check name cond = if not cond then failwith ("FAIL: " ^ name)

let is_class name expected ir =
  let got = risk_of ir in
  if got <> expected then
    failwith
      (Printf.sprintf "FAIL: %s — expected %s, got %s" name
         (Risk.string_of_risk_class expected)
         (Risk.string_of_risk_class got))
;;

(* find -delete / -exec / -execdir / -ok / -okdir → Destructive_protected:
   delete or arbitrary-command exec (rm/sh are on no keeper allowlist), so
   blocked for ALL keepers including write-enabled dev. *)
let test_find_destructive () =
  is_class "find -delete" Risk.Destructive_protected (parse "find . -delete");
  is_class "find -name + -delete" Risk.Destructive_protected
    (parse "find . -name *.tmp -delete");
  (* find -exec: bash parser rejects the `;`/`{}` form, so the typed-input
     path is the reachable one — and the one a parser-only fix would miss. *)
  is_class "{find,.,-exec,rm,-rf,{},;} (typed)" Risk.Destructive_protected
    (typed_simple "find" [ "."; "-exec"; "rm"; "-rf"; "{}"; ";" ]);
  is_class "{find,.,-execdir,sh,;} (typed)" Risk.Destructive_protected
    (typed_simple "find" [ "."; "-execdir"; "sh"; ";" ]);
  is_class "{find,.,-delete} (typed)" Risk.Destructive_protected
    (typed_simple "find" [ "."; "-delete" ]);
  (* The keeper pre-gate keys on is_destructive (blocks all tool_access). *)
  check "find -delete is_destructive" (Risk.is_destructive (envelope (parse "find . -delete")))
;;

(* find -fprintf / -fls / -fprint / -fprint0 write a named file: R1
   (readonly blocked by pre-gate, dev allowed — an ordinary write). *)
let test_find_write () =
  is_class "find -fprintf" Risk.R1_Reversible_mutation (parse "find . -fprintf out.txt %p");
  is_class "find -fls" Risk.R1_Reversible_mutation (parse "find . -fls out.txt");
  is_class "{find,.,-fprint,out} (typed)" Risk.R1_Reversible_mutation
    (typed_simple "find" [ "."; "-fprint"; "out.txt" ])
;;

(* sed -i / -i.bak / --in-place edit files in place: R1. *)
let test_sed_in_place () =
  is_class "sed -i" Risk.R1_Reversible_mutation (parse "sed -i s/a/b/ file.txt");
  is_class "sed -i.bak" Risk.R1_Reversible_mutation (parse "sed -i.bak s/a/b/ file.txt");
  is_class "{sed,-i,s/a/b/,f} (typed)" Risk.R1_Reversible_mutation
    (typed_simple "sed" [ "-i"; "s/a/b/"; "file.txt" ]);
  check "sed -i is_r1" (Risk.is_r1 (envelope (parse "sed -i s/a/b/ file.txt")))
;;

(* sort -o / --output write a file: R1. *)
let test_sort_output () =
  is_class "sort -o" Risk.R1_Reversible_mutation (parse "sort -o out.txt in.txt");
  is_class "{sort,-o,out,in} (typed)" Risk.R1_Reversible_mutation
    (typed_simple "sort" [ "-o"; "out.txt"; "in.txt" ])
;;

(* Legitimate read uses stay R0 — no false-reject of normal find/sed/sort
   searching/filtering. *)
let test_legit_reads_preserved () =
  is_class "find -type f" Risk.R0_Read (parse "find . -type f");
  is_class "find -name" Risk.R0_Read (parse "find . -name foo.txt");
  is_class "sed (no -i)" Risk.R0_Read (parse "sed s/a/b/ file.txt");
  is_class "sort (no -o)" Risk.R0_Read (parse "sort in.txt");
  let legit = envelope (parse "find . -type f") in
  check "find -type f not gated"
    (not (Risk.is_destructive legit)
     && not (Risk.is_r1 legit)
     && not (Risk.is_r2 legit))
;;

let () =
  test_find_destructive ();
  test_find_write ();
  test_sed_in_place ();
  test_sort_output ();
  test_legit_reads_preserved ();
  print_endline "[test_shell_ir_risk_action_flags] all tests passed"
;;
