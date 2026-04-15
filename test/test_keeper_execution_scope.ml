(** Unit tests for Keeper_execution_scope typed variant.

    Verifies round-trip encoding, unknown rejection, case normalization,
    and wire-compatibility with the legacy string representation. *)

open Alcotest
module KES = Masc_mcp.Keeper_execution_scope

let scope_testable =
  testable
    (fun fmt v -> Format.pp_print_string fmt (KES.to_string v))
    KES.equal

let test_roundtrip () =
  List.iter
    (fun scope ->
       let s = KES.to_string scope in
       match KES.of_string s with
       | Ok back -> check scope_testable ("roundtrip " ^ s) scope back
       | Error (`Unknown_scope u) ->
           fail (Printf.sprintf "of_string rejected its own output: %S" u))
    KES.all

let test_wire_values () =
  check string "observe_only wire" "observe_only" (KES.to_string Observe_only);
  check string "workspace wire" "workspace" (KES.to_string Workspace);
  check string "local wire" "local" (KES.to_string Local)

let test_case_normalization () =
  check (result scope_testable reject)
    "OBSERVE_ONLY" (Ok KES.Observe_only) (KES.of_string "OBSERVE_ONLY");
  check (result scope_testable reject)
    "Workspace" (Ok KES.Workspace) (KES.of_string "Workspace");
  check (result scope_testable reject)
    "  LOCAL  " (Ok KES.Local) (KES.of_string "  LOCAL  ")

let test_unknown_rejected () =
  match KES.of_string "playground" with
  | Error (`Unknown_scope _) -> ()
  | Ok v ->
      fail
        (Printf.sprintf "expected Error for 'playground', got Ok %s"
           (KES.to_string v))

let test_lossy_default () =
  check scope_testable
    "lossy unknown → default"
    KES.Workspace
    (KES.of_string_lossy "garbage");
  check scope_testable
    "lossy unknown → custom default"
    KES.Local
    (KES.of_string_lossy ~default:KES.Local "garbage");
  check scope_testable
    "lossy valid → parsed"
    KES.Observe_only
    (KES.of_string_lossy "observe_only")

let test_default_is_workspace () =
  check scope_testable "default" KES.Workspace KES.default

let test_all_exhaustive () =
  check int "all length" 3 (List.length KES.all);
  List.iter
    (fun scope ->
       let found = List.exists (KES.equal scope) KES.all in
       check bool ("all contains " ^ KES.to_string scope) true found)
    [ KES.Observe_only; KES.Workspace; KES.Local ]

let () =
  run "Keeper_execution_scope"
    [ "roundtrip", [ test_case "to_string -> of_string" `Quick test_roundtrip ]
    ; "wire", [ test_case "legacy wire values" `Quick test_wire_values ]
    ; "normalization",
      [ test_case "case and whitespace" `Quick test_case_normalization ]
    ; "rejection",
      [ test_case "unknown scope rejected" `Quick test_unknown_rejected ]
    ; "lossy",
      [ test_case "of_string_lossy fallback" `Quick test_lossy_default ]
    ; "default",
      [ test_case "default is Workspace" `Quick test_default_is_workspace ]
    ; "all",
      [ test_case "all variants present" `Quick test_all_exhaustive ]
    ]
