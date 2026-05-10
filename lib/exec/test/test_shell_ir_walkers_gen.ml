(** RFC-0054 PR-3 → PR-5 — generated walker correctness test.

    PR-5 retired the hand-written walkers in [Shell_ir_typed]; the
    public API ([risk], [sandbox], [to_simple]) now delegates directly
    to [Shell_ir_typed_walkers_gen].  The equivalence tests below are
    retained as a round-trip smoke test (they are trivially true now
    since both sides call the same generated function).  The structural
    invariants — constructor count and declaration order — remain the
    primary regression guard. *)

open Masc_exec

let bin_ok name =
  match Bin.of_string name with
  | Ok b -> b
  | Error _ -> assert false
;;

let lit s = Shell_ir.Lit s

(* Construct one [W] for each constructor with minimal payload. The
   payload values do not affect [risk] or [sandbox] (both walk only on
   the constructor head), but constructor coverage is checked
   structurally below. *)
let all_wrapped : Shell_ir_typed.wrapped list =
  let open Shell_ir_typed in
  [ W (Ls { path = None; flags = [] })
  ; W (Cat { path = "/dev/null" })
  ; W (Rg { pattern = "."; path = None; case_sensitive = false })
  ; W (Git_status { short = false })
  ; W (Git_clone { repo = "x"; branch = None; depth = 1 })
  ; W (Curl { url = "http://x"; method_ = `GET; headers = None; body = None })
  ; W (Rm { paths = []; recursive = false; force = false })
  ; W (Sudo { target_argv = [] })
  ; W
      (Generic
         { Shell_ir.bin = bin_ok "true"
         ; args = []
         ; env = []
         ; cwd = None
         ; redirects = []
         ; sandbox = Sandbox_target.host ()
         })
  ]
;;

let test_risk_parallel_equivalence () =
  List.iter
    (fun w ->
       let hand = Shell_ir_typed.risk w in
       let gen = Shell_ir_typed_walkers_gen.gen_risk w in
       Alcotest.(check bool)
         (Printf.sprintf
            "risk equivalence for %s"
            (match w with
             | Shell_ir_typed.W _ -> "constructor"))
         true
         (hand = gen))
    all_wrapped
;;

let test_sandbox_parallel_equivalence () =
  List.iter
    (fun w ->
       let hand = Shell_ir_typed.sandbox w in
       let gen = Shell_ir_typed_walkers_gen.gen_sandbox w in
       Alcotest.(check bool)
         (Printf.sprintf
            "sandbox equivalence for %s"
            (match w with
             | Shell_ir_typed.W _ -> "constructor"))
         true
         (hand = gen))
    all_wrapped
;;

(* PR-4: gen_to_simple parallel equivalence. The hand-written
   [Shell_ir_typed.to_simple] takes the unwrapped command directly,
   so the test unwraps each [W (...)] and feeds both walkers the
   same input. Equality is structural — each [Shell_ir.simple] field
   must match: bin, args, env, cwd, redirects, sandbox. *)
let simple_eq (a : Shell_ir.simple) (b : Shell_ir.simple) : bool =
  Bin.to_string a.bin = Bin.to_string b.bin
  && a.args = b.args
  && a.env = b.env
  && a.cwd = b.cwd
  && a.redirects = b.redirects
  && a.sandbox = b.sandbox
;;

let pp_simple ppf (s : Shell_ir.simple) =
  Format.fprintf
    ppf
    "{ bin=%s; args=%d; env=%d; cwd=%s; redirects=%d }"
    (Bin.to_string s.bin)
    (List.length s.args)
    (List.length s.env)
    (match s.cwd with
     | None -> "None"
     | Some _ -> "Some _")
    (List.length s.redirects)
;;

let test_to_simple_parallel_equivalence () =
  List.iter
    (fun (Shell_ir_typed.W cmd as w) ->
       let hand = Shell_ir_typed.to_simple cmd in
       let gen = Shell_ir_typed_walkers_gen.gen_to_simple cmd in
       let _ = w in
       if not (simple_eq hand gen)
       then Alcotest.failf "to_simple drift: hand=%a gen=%a" pp_simple hand pp_simple gen)
    all_wrapped
;;

let test_constructor_count () =
  (* Baseline: 9 constructors as of 2026-05-09. If this fails, either
     a constructor was added to shell_ir_typed.ml without updating the
     spec in bin/gen_shell_ir_walkers.ml (regression) or the count is
     intentional and this test should bump along with the spec. *)
  Alcotest.(check int)
    "generated constructor count"
    9
    (List.length Shell_ir_typed_walkers_gen.gen_constructor_names);
  Alcotest.(check int) "test fixture covers all constructors" 9 (List.length all_wrapped)
;;

(* PR-4 round-trip: of_simple ∘ to_simple = identity for every
   non-Generic constructor.  Generic is handled in the fallback test
   below. *)
let test_of_simple_round_trip () =
  let open Shell_ir_typed in
  let cmds : wrapped list =
    [ W (Ls { path = None; flags = [] })
    ; W (Ls { path = Some "/tmp"; flags = [ `Long; `All ] })
    ; W (Cat { path = "/etc/passwd" })
    ; W (Rg { pattern = "TODO"; path = Some "."; case_sensitive = true })
    ; W (Git_status { short = true })
    ; W (Git_clone { repo = "git@github.com:x/y.git"; branch = Some "main"; depth = 1 })
    ; W (Curl { url = "http://example.com"; method_ = `POST; headers = Some [ ("A", "B") ]; body = Some "data" })
    ; W (Rm { paths = [ "a"; "b" ]; recursive = true; force = false })
    ; W (Sudo { target_argv = [ "whoami" ] })
    ]
  in
  List.iter
    (fun (W cmd as w) ->
       let simple = Shell_ir_typed.to_simple cmd in
       let back = Shell_ir_typed.of_simple simple in
       if not (w = back)
       then Alcotest.failf "of_simple round-trip failed for %a" Shell_ir_typed.pp w)
    cmds
;;

(* PR-4 fallback: anything with env, redirects, Var args, or an
   unhandled binary kind must round-trip through Generic. *)
let test_of_simple_generic_fallback () =
  let base =
    { Shell_ir.bin = bin_ok "true"
    ; args = [ lit "x" ]
    ; env = []
    ; cwd = None
    ; redirects = []
    ; sandbox = Sandbox_target.host ()
    }
  in
  (* env non-empty *)
  let w_env = Shell_ir_typed.of_simple { base with env = [ ("K", lit "V") ] } in
  Alcotest.(check bool) "env fallback" true
    (match w_env with Shell_ir_typed.W (Generic _) -> true | _ -> false);
  (* redirects non-empty *)
  let w_redir =
    Shell_ir_typed.of_simple
      { base with
        redirects =
          [ Redirect_scope.File
              { fd = 1
              ; target = Path_scope.classify ~raw:"/tmp/x" ~cwd:"/tmp"
              ; mode = Redirect_scope.Write
              }
          ]
      }
  in
  Alcotest.(check bool) "redirect fallback" true
    (match w_redir with Shell_ir_typed.W (Generic _) -> true | _ -> false);
  (* Var arg *)
  let w_var = Shell_ir_typed.of_simple { base with args = [ Shell_ir.Var "X" ] } in
  Alcotest.(check bool) "var fallback" true
    (match w_var with Shell_ir_typed.W (Generic _) -> true | _ -> false);
  (* unknown binary kind *)
  let w_unknown =
    Shell_ir_typed.of_simple { base with bin = bin_ok "docker"; args = [ lit "ps" ] }
  in
  Alcotest.(check bool) "unknown bin fallback" true
    (match w_unknown with Shell_ir_typed.W (Generic _) -> true | _ -> false);
  (* git sub-command we do not parse *)
  let w_git_push =
    Shell_ir_typed.of_simple
      { base with bin = bin_ok "git"; args = [ lit "push"; lit "origin" ] }
  in
  Alcotest.(check bool) "git push fallback" true
    (match w_git_push with Shell_ir_typed.W (Generic _) -> true | _ -> false)
;;

let test_constructor_names_in_declaration_order () =
  Alcotest.(check (list string))
    "generated names match declaration order"
    [ "Ls"; "Cat"; "Rg"; "Git_status"; "Git_clone"; "Curl"; "Rm"; "Sudo"; "Generic" ]
    Shell_ir_typed_walkers_gen.gen_constructor_names
;;

let () =
  Alcotest.run
    "shell_ir_walkers_gen"
    [ ( "golden_equivalence"
      , [ Alcotest.test_case
            "risk: hand-written = generated"
            `Quick
            test_risk_parallel_equivalence
        ; Alcotest.test_case
            "sandbox: hand-written = generated"
            `Quick
            test_sandbox_parallel_equivalence
        ; Alcotest.test_case
            "to_simple: hand-written = generated"
            `Quick
            test_to_simple_parallel_equivalence
        ] )
    ; ( "of_simple_round_trip"
      , [ Alcotest.test_case "of_simple ∘ to_simple = id" `Quick test_of_simple_round_trip
        ; Alcotest.test_case "Generic fallback coverage" `Quick test_of_simple_generic_fallback
        ] )
    ; ( "spec_invariants"
      , [ Alcotest.test_case "constructor count baseline" `Quick test_constructor_count
        ; Alcotest.test_case
            "constructor names declaration-order"
            `Quick
            test_constructor_names_in_declaration_order
        ] )
    ]
;;
