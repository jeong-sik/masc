(** Shell_ir_typed tests — round-trip, risk/sandbox extractors, capability mapping. *)

open Masc_exec

let bin_ok name =
  match Bin.of_string name with
  | Ok b -> b
  | Error _ -> assert false

let simple ?(args = []) ?(env = []) ?(cwd = None) ?(redirects = [])
    ?(sandbox = Sandbox_target.host ()) bin
    : Shell_ir.simple =
  { bin; args; env; cwd; redirects; sandbox }

let lit s = Shell_ir.Lit s

let arg_to_string = function
  | Shell_ir.Lit s -> s
  | Shell_ir.Var _ | Shell_ir.Concat _ ->
    assert false (* tests use only literal args *)

let argv_of_simple s =
  Bin.to_string s.Shell_ir.bin :: List.map arg_to_string s.Shell_ir.args

(* ---------------------------------------------------------------------- *)
(* Round-trip: simple -> of_simple -> to_simple -> identical argv *)

let roundtrip simple =
  let (Shell_ir_typed.W cmd) = Shell_ir_typed.of_simple simple in
  let reconstructed = Shell_ir_typed.to_simple cmd in
  let orig = argv_of_simple simple in
  let next = argv_of_simple reconstructed in
  assert (orig = next)

let test_ls_roundtrip () =
  let _ = roundtrip (simple ~args:[lit "-l"; lit "-a"] (bin_ok "ls")) in
  ()

let test_cat_roundtrip () =
  let _ = roundtrip (simple ~args:[lit "/etc/passwd"] (bin_ok "cat")) in
  ()

let test_rg_roundtrip () =
  let _ = roundtrip (simple ~args:[lit "-i"; lit "foo"; lit "."] (bin_ok "rg")) in
  ()

let test_git_status_roundtrip () =
  let _ = roundtrip (simple ~args:[lit "status"; lit "-s"] (bin_ok "git")) in
  ()

let test_git_clone_roundtrip () =
  let _ =
    roundtrip
      (simple
         ~args:[lit "clone"; lit "https://github.com/foo/bar.git"]
         (bin_ok "git"))
  in
  ()

let test_curl_get_roundtrip () =
  let _ = roundtrip (simple ~args:[lit "https://example.com"] (bin_ok "curl")) in
  ()

let test_curl_post_roundtrip () =
  let _ =
    roundtrip
      (simple
         ~args:[
           lit "-X"; lit "POST";
           lit "-H"; lit "Content-Type: application/json";
           lit "-d"; lit "{}";
           lit "https://example.com"
         ]
         (bin_ok "curl"))
  in
  ()

let test_rm_roundtrip () =
  let _ = roundtrip (simple ~args:[lit "-r"; lit "-f"; lit "/tmp/old"] (bin_ok "rm")) in
  ()

let test_sudo_roundtrip () =
  let _ = roundtrip (simple ~args:[lit "apt"; lit "update"] (bin_ok "sudo")) in
  ()

(* ---------------------------------------------------------------------- *)
(* Risk / Sandbox extractors *)

let test_risk_levels () =
  let check simple expected =
    let w = Shell_ir_typed.of_simple simple in
    assert (Shell_ir_typed.risk w = expected)
  in
  check (simple (bin_ok "ls")) `Safe;
  check (simple (bin_ok "cat")) `Safe;
  check (simple (bin_ok "rg")) `Safe;
  check (simple ~args:[lit "status"] (bin_ok "git")) `Audited;
  check (simple ~args:[lit "clone"; lit "x"] (bin_ok "git")) `Audited;
  check (simple (bin_ok "curl")) `Audited;
  check (simple (bin_ok "rm")) `Privileged;
  check (simple (bin_ok "sudo")) `Privileged

let test_sandbox_levels () =
  let check simple expected =
    let w = Shell_ir_typed.of_simple simple in
    assert (Shell_ir_typed.sandbox w = expected)
  in
  check (simple (bin_ok "ls")) `Host;
  check (simple (bin_ok "cat")) `Host;
  check (simple (bin_ok "rg")) `Host;
  check (simple ~args:[lit "status"] (bin_ok "git")) `Host;
  check (simple ~args:[lit "clone"; lit "x"] (bin_ok "git")) `Docker;
  check (simple (bin_ok "curl")) `Host;
  check (simple (bin_ok "rm")) `Host;
  check (simple (bin_ok "sudo")) `Host

(* ---------------------------------------------------------------------- *)
(* Capability_check_typed — total extraction, no None fallthrough *)

let test_capability_extraction_is_total () =
  let check simple =
    let w = Shell_ir_typed.of_simple simple in
    let caps = Capability_check_typed.of_command w in
    assert (List.length caps > 0)
  in
  check (simple (bin_ok "ls"));
  check (simple ~args:[lit "status"] (bin_ok "git"));
  check (simple (bin_ok "curl"));
  check (simple (bin_ok "rm"));
  check (simple (bin_ok "sudo"))

let test_generic_falls_back_to_capability_check () =
  (* An unknown binary becomes Generic, which delegates to Capability_check.of_simple *)
  let simple = simple (bin_ok "dd") in
  let w = Shell_ir_typed.of_simple simple in
  (match Shell_ir_typed.risk w with
   | `Privileged -> ()
   | _ -> assert false);
  let caps = Capability_check_typed.of_command w in
  assert (List.length caps > 0)

(* ---------------------------------------------------------------------- *)

let () =
  test_ls_roundtrip ();
  test_cat_roundtrip ();
  test_rg_roundtrip ();
  test_git_status_roundtrip ();
  test_git_clone_roundtrip ();
  test_curl_get_roundtrip ();
  test_curl_post_roundtrip ();
  test_rm_roundtrip ();
  test_sudo_roundtrip ();
  test_risk_levels ();
  test_sandbox_levels ();
  test_capability_extraction_is_total ();
  test_generic_falls_back_to_capability_check ();
  print_endline "[test_shell_ir_typed] all tests passed"
