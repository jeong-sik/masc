(** #10488: [nonempty_lines] keeps a trailing tab.

    The live [docker inspect] template prints twelve tab-separated fields
    per container. When the last label, the TTL
    ([sandbox_ttl_sec_label_key]), is missing the
    line ends with a tab, and [parse_live_container_line] matches exactly
    twelve fields. [String.trim] used to drop that tab. *)

open Alcotest
module R = Masc.Keeper_sandbox_runtime.For_testing

let test_nonempty_lines_preserves_trailing_tab () =
  let raw = "f1\tf2\tf3\t\n" in
  match R.nonempty_lines raw with
  | [ line ] ->
      check string "trailing tab preserved" "f1\tf2\tf3\t" line
  | other ->
      failf "expected single line, got %d: [%s]"
        (List.length other) (String.concat " | " other)

let () =
  run "sandbox_inspect_trim_10488" [
    ("nonempty_lines", [
        test_case "preserves a trailing tab"
          `Quick test_nonempty_lines_preserves_trailing_tab;
      ]);
  ]
