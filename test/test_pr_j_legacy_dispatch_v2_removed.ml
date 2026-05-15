open Alcotest

(** RFC-0084 host-config-cleanup-J — Legacy MASC_DISPATCH_V2 removal.

    PR-J removes the [MASC_DISPATCH_V2] feature flag and the
    [Tool_dispatch.v2_enabled] / [Env_config.Tools.dispatch_v2_enabled]
    accessors that read it.  The legacy match chain the flag once
    gated was already dead (default ON since v2.102, no live caller
    used the [false] branch), so removal is net-deletion only.

    The pins guard against any of those re-appearing:
    - [MASC_DISPATCH_V2] string literal must not appear in lib/
    - [v2_enabled] identifier must not appear in lib/tool_dispatch.{ml,mli}
    - [dispatch_v2_enabled] JSON field must not appear in
      lib/tool_unified.ml's report assoc *)

let pinned_masc_dispatch_v2_in_lib = 0
let pinned_v2_enabled_in_tool_dispatch = 0
let pinned_dispatch_v2_enabled_json_field = 0

let read_file path =
  match In_channel.with_open_text path In_channel.input_all with
  | exception _ -> ""
  | content -> content
;;

let count_substring ~haystack ~needle =
  let rec loop i acc =
    let next = String.index_from_opt haystack i needle.[0] in
    match next with
    | None -> acc
    | Some j ->
      let len = String.length needle in
      if j + len <= String.length haystack
         && String.sub haystack j len = needle
      then loop (j + len) (acc + 1)
      else loop (j + 1) acc
  in
  loop 0 0
;;

let count_across_files ~files ~needle =
  List.fold_left
    (fun acc path ->
      acc + count_substring ~haystack:(read_file path) ~needle)
    0 files
;;

let test_no_masc_dispatch_v2_in_lib () =
  let files =
    [ "lib/config/env_config_runtime.ml"
    ; "lib/config/env_config_runtime.mli"
    ; "lib/config/env_config_snapshot.ml"
    ; "lib/config/feature_flag_registry.ml"
    ; "lib/tool_dispatch.ml"
    ; "lib/tool_dispatch.mli"
    ; "lib/tool_unified.ml"
    ]
  in
  let occurrences = count_across_files ~files ~needle:{|"MASC_DISPATCH_V2"|} in
  (check int)
    "literal `\"MASC_DISPATCH_V2\"` must be 0 in flag registry / \
     env_config / dispatch / unified after PR-J"
    pinned_masc_dispatch_v2_in_lib occurrences
;;

let test_no_v2_enabled_in_tool_dispatch () =
  let files = [ "lib/tool_dispatch.ml"; "lib/tool_dispatch.mli" ] in
  (* Match `v2_enabled` as a whole word (preceded/followed by
     non-identifier chars).  Two needles cover the live-code shapes
     ([let v2_enabled], [val v2_enabled], [Tool_dispatch.v2_enabled]). *)
  let needles =
    [ "let v2_enabled "; "val v2_enabled "; ".v2_enabled" ]
  in
  let occurrences =
    List.fold_left
      (fun acc needle -> acc + count_across_files ~files ~needle)
      0 needles
  in
  (check int)
    "live-code [v2_enabled] occurrences in tool_dispatch.{ml,mli} \
     must be 0 after PR-J"
    pinned_v2_enabled_in_tool_dispatch occurrences
;;

let test_no_dispatch_v2_enabled_json_field () =
  let content = read_file "lib/tool_unified.ml" in
  let occurrences =
    count_substring ~haystack:content ~needle:{|"dispatch_v2_enabled"|}
  in
  (check int)
    "JSON field `\"dispatch_v2_enabled\"` in lib/tool_unified.ml must \
     be 0 after PR-J"
    pinned_dispatch_v2_enabled_json_field occurrences
;;

let () =
  run
    "PR-J host-config-cleanup-J (legacy MASC_DISPATCH_V2 removal)"
    [ ( "pr-j-legacy-dispatch-removed"
      , [ test_case "no-masc-dispatch-v2-in-lib" `Quick
            test_no_masc_dispatch_v2_in_lib
        ; test_case "no-v2-enabled-in-tool-dispatch" `Quick
            test_no_v2_enabled_in_tool_dispatch
        ; test_case "no-dispatch-v2-enabled-json-field" `Quick
            test_no_dispatch_v2_enabled_json_field
        ] )
    ]
;;
