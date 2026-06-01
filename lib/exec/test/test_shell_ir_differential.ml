(* RFC-0208 P2 — differential-safety harness.

   Purpose: gate the eventual retirement of the word-list floor (P6) on
   *evidence*, not assertion. For a corpus of commands the harness:

   1. asserts the monotone-safety invariant — the full composed verdict is
      never below the legacy word-list floor (so the typed path can only
      escalate, never silently downgrade); and
   2. reports the floor-redundancy rate — the fraction of the corpus where
      the typed model *alone* already dominates the floor. A command-class
      may leave the floor only when that fraction reaches 100% for it; the
      load-bearing remainder is the work-list for the typed model (P3+).

   The harness is deterministic (curated corpus, no RNG) for
   reproducibility. It runs on constructed IRs via the exported
   classifiers, so it needs only masc_exec — independent of the keeper
   build. *)

module IR = Masc_exec.Shell_ir
module Risk = Masc_exec.Shell_ir_risk
module Typed = Masc_exec.Shell_ir_typed

let bin s = Result.get_ok (Masc_exec.Exec_program.of_string s)

let simple_ir bin_str args =
  IR.Simple
    { IR.bin = bin bin_str
    ; args = List.map (fun a -> IR.Lit (a, IR.default_meta)) args
    ; env = []
    ; cwd = None
    ; redirects = []
    ; sandbox = Masc_exec.Sandbox_target.host ()
    }
;;

let pipeline_ir stages = IR.Pipeline (List.map (fun (b, a) -> simple_ir b a) stages)

let rank = function
  | Risk.R0_Read -> 0
  | Risk.R1_Reversible_mutation -> 1
  | Risk.R2_Irreversible -> 2
  | Risk.Destructive_protected -> 3
;;

let max_rc a b = if rank a >= rank b then a else b
let ge a b = rank a >= rank b

(* A corpus entry is a single command or a pipeline of stages. *)
type entry =
  | S of string * string list
  | P of (string * string list) list

let ir_of = function
  | S (b, a) -> simple_ir b a
  | P stages -> pipeline_ir stages
;;

let words_of = function
  | S (b, a) -> b :: a
  | P stages -> List.concat_map (fun (b, a) -> b :: a) stages
;;

let label = function
  | S (b, a) -> String.concat " " (b :: a)
  | P stages ->
    String.concat " | " (List.map (fun (b, a) -> String.concat " " (b :: a)) stages)
;;

(* Typed-only verdict: the per-stage [risk_of_typed] fold WITHOUT the
   word-list floor. This is what [classify] would return if the floor were
   removed — the quantity floor-retirement readiness is measured against. *)
let rec typed_only (ir : IR.t) : Risk.risk_class =
  match ir with
  | IR.Simple s -> Risk.risk_of_typed (Typed.of_simple s)
  | IR.Pipeline stages ->
    List.fold_left (fun acc st -> max_rc acc (typed_only st)) Risk.R0_Read stages
;;

(* Representative keeper traffic + adversarial edge cases across the risk
   spectrum. Grows as new command-classes are typed. *)
let corpus =
  [ (* reads *)
    S ("ls", [ "-la" ])
  ; S ("cat", [ "file.txt" ])
  ; S ("rg", [ "pattern"; "lib/" ])
  ; S ("git", [ "status" ])
  ; S ("git", [ "log"; "--oneline" ])
  ; S ("pwd", [])
  ; S ("echo", [ "hello" ])
  ; S ("wc", [ "-l"; "file" ])
  ; S ("gh", [ "pr"; "view"; "123" ])
  ; P [ ("ls", []); ("grep", [ "x" ]) ]
  ; P [ ("cat", [ "f" ]); ("wc", [ "-l" ]) ]
    (* reversible writes *)
  ; S ("git", [ "commit"; "-m"; "msg" ])
  ; S ("git", [ "push" ])
  ; S ("git", [ "checkout"; "-b"; "feature" ])
  ; S ("npm", [ "install" ])
  ; S ("mkdir", [ "-p"; "dir" ])
  ; S ("touch", [ "file" ])
  ; S ("gh", [ "pr"; "create"; "--title"; "t" ])
    (* irreversible *)
  ; S ("git", [ "reset"; "--hard"; "HEAD~1" ])
  ; S ("rm", [ "file" ])
  ; S ("gh", [ "pr"; "merge"; "123" ])
    (* destructive / privileged *)
  ; S ("git", [ "push"; "--force"; "origin"; "main" ])
  ; S ("rm", [ "-rf"; "dir" ])
  ; S ("sudo", [ "rm"; "-rf"; "/" ])
  ; P [ ("echo", [ "x" ]); ("sudo", [ "tee"; "/etc/passwd" ]) ]
  ; P [ ("cat", [ "f" ]); ("git", [ "push"; "--force"; "origin"; "main" ]) ]
    (* floor-load-bearing candidates: method/body buried in rest *)
  ; S ("gh", [ "api"; "-X"; "DELETE"; "/repos/o/r" ])
  ; S ("gh", [ "api"; "-X"; "POST"; "/repos/o/r/issues" ])
  ; S ("gh", [ "api"; "graphql"; "-f"; "query=mutation{deleteRef}" ])
    (* unknown binary -> Generic escape hatch *)
  ; S ("my-custom-tool", [ "--help" ])
  ; P [ ("ls", []); ("my-custom-tool", []) ]
  ]
;;

(* Invariant: full verdict never drops below the floor or the typed-only
   verdict. If this ever fails, the composed classifier silently weakened a
   command — a safety regression. *)
let test_monotone_safety () =
  List.iter
    (fun e ->
       let ir = ir_of e in
       let full = (Risk.classify (Risk.undecided ir)).Risk.risk in
       let floor = Risk.classify_words (words_of e) in
       let typed = typed_only ir in
       Alcotest.(check bool)
         (Printf.sprintf
            "%s: full=%s >= floor=%s"
            (label e)
            (Risk.string_of_risk_class full)
            (Risk.string_of_risk_class floor))
         true
         (ge full floor);
       Alcotest.(check bool)
         (Printf.sprintf
            "%s: full=%s >= typed_only=%s"
            (label e)
            (Risk.string_of_risk_class full)
            (Risk.string_of_risk_class typed))
         true
         (ge full typed))
    corpus
;;

(* A command whose risk is irreducibly string-borne: [risk_of_typed]
   returns R0 by design and the word-list floor owns it permanently
   (RFC-0208 B1). gh is the only such class today. These are EXPECTED to
   stay load-bearing — they are not a typing work-list and never reach
   floor-retirement readiness. Floor-retirement readiness is therefore
   judged on the STRUCTURAL load-bearing remainder only. *)
let is_string_borne = function
  | S (b, _) -> b = "gh"
  | P stages -> List.exists (fun (b, _) -> b = "gh") stages
;;

(* Report: typed coverage and floor-retirement readiness. The load-bearing
   list is the set of commands the floor still classifies stricter than the
   typed model — i.e. the floor cannot be dropped for these yet. It is split
   into a structural work-list (should reach 0) and the string-borne classes
   (gh; floor-owned by design). *)
let test_report_floor_readiness () =
  let n = List.length corpus in
  Alcotest.(check bool) "harness ran over a non-empty corpus" true (n > 0);
  let typed_hits = List.filter (fun e -> Risk.typed_hit_of_ir (ir_of e)) corpus in
  let load_bearing =
    List.filter
      (fun e -> not (ge (typed_only (ir_of e)) (Risk.classify_words (words_of e))))
      corpus
  in
  let string_borne, structural = List.partition is_string_borne load_bearing in
  let redundant = n - List.length load_bearing in
  let pct x = 100.0 *. float_of_int x /. float_of_int n in
  Printf.printf "\n=== RFC-0208 P2 differential-safety harness ===\n";
  Printf.printf "corpus: %d commands\n" n;
  Printf.printf
    "typed_hit (non-Generic): %d/%d (%.0f%%)\n"
    (List.length typed_hits)
    n
    (pct (List.length typed_hits));
  Printf.printf
    "floor-redundant (typed_only >= floor): %d/%d (%.0f%%)\n"
    redundant
    n
    (pct redundant);
  Printf.printf
    "floor still load-bearing: %d (structural: %d, string-borne/gh: %d)\n"
    (List.length load_bearing)
    (List.length structural)
    (List.length string_borne);
  let print_entry e =
    Printf.printf
      "  - %s  (typed_only=%s, floor=%s)\n"
      (label e)
      (Risk.string_of_risk_class (typed_only (ir_of e)))
      (Risk.string_of_risk_class (Risk.classify_words (words_of e)))
  in
  if structural <> [] then begin
    Printf.printf "structural load-bearing (typing work-list, should reach 0):\n";
    List.iter print_entry structural
  end;
  if string_borne <> [] then begin
    Printf.printf "string-borne load-bearing (gh; floor-owned by design, expected):\n";
    List.iter print_entry string_borne
  end;
  Printf.printf
    "floor retirement readiness (structural classes only): %s\n"
    (if structural = []
     then
       "READY — typed model dominates every structurally-typed class; the \
        floor remains only for string-borne gh by design"
     else
       Printf.sprintf
         "NOT READY — %d structural command-class(es) still need the floor"
         (List.length structural));
  (* The harness reports; it never auto-retires the floor. *)
  ()
;;

(* RFC-0208 P3 ratchet: these classes are closed by GENUINELY typed
   classifier arms (git checkout -> R1, git reset -> R2) whose risk is
   structural and read directly from the typed shape. They must stay
   floor-redundant; a regression here means a typed arm was weakened back
   below the floor. gh is deliberately NOT in this list: gh risk is
   string-borne (HTTP method / -f fields / graphql body), so [risk_of_typed]
   returns R0 and the word-list floor owns gh by design (RFC-0208 B1). gh
   commands therefore stay load-bearing in the readiness report — that is
   the honest state, not a regression. *)
let test_p3_closed_redundant () =
  let closed =
    [ S ("git", [ "checkout"; "-b"; "feature" ])
    ; S ("git", [ "reset"; "--hard"; "HEAD~1" ])
    ]
  in
  List.iter
    (fun e ->
       Alcotest.(check bool)
         (Printf.sprintf "%s floor-redundant (typed_only >= floor)" (label e))
         true
         (ge (typed_only (ir_of e)) (Risk.classify_words (words_of e))))
    closed
;;

let () =
  test_monotone_safety ();
  test_report_floor_readiness ();
  test_p3_closed_redundant ();
  print_endline "test_shell_ir_differential: harness passed"
;;
