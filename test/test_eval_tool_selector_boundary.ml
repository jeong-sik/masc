open Alcotest

(** [Eval_tool_selector] is an eval/shadow/replay matcher over recorded
    tool-call evidence. It must not become live keeper/runtime routing policy. *)

let guarded_roots = [ "lib/keeper"; "lib/runtime" ]

let rec collect_sources dir acc =
  let entries = try Sys.readdir dir with Sys_error _ -> [||] in
  Array.fold_left
    (fun acc name ->
      let path = Filename.concat dir name in
      if (try Sys.is_directory path with Sys_error _ -> false)
      then collect_sources path acc
      else if Filename.check_suffix path ".ml" || Filename.check_suffix path ".mli"
      then path :: acc
      else acc)
    acc
    entries
;;

let read_file path =
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () -> really_input_string ic (in_channel_length ic))
;;


let test_not_used_by_live_keeper_or_runtime () =
  let files = List.fold_left (fun acc root -> collect_sources root acc) [] guarded_roots in
  let offenders =
    files
    |> List.filter (fun path ->
      String_util.string_contains_substring ~needle:"Eval_tool_selector" (read_file path))
    |> List.sort String.compare
  in
  match offenders with
  | [] -> ()
  | _ ->
    failf
      "Eval_tool_selector is eval-only and must not be imported by live \
       keeper/runtime code: %s"
      (String.concat ", " offenders)
;;

(* [to_yojson] writes a ["type"]-tagged object. Every other JSON shape decodes
   to a typed error, so a malformed selector cannot fold into a name match that
   silently weakens the expectation it was written for. *)
let decodes raw = Eval_tool_selector.of_yojson (Yojson.Safe.from_string raw)

let test_accepts_the_shapes_to_yojson_writes () =
  List.iter
    (fun (selector, expected_label) ->
      match decodes (Yojson.Safe.to_string (Eval_tool_selector.to_yojson selector)) with
      | Ok decoded -> check string "round trip" expected_label (Eval_tool_selector.label decoded)
      | Error message -> failf "%s should decode: %s" expected_label message)
    [ Eval_tool_selector.Tool_name "tool_execute", "tool_name:tool_execute"
    ; Eval_tool_selector.Descriptor_id "masc.agent.card", "descriptor_id:masc.agent.card"
    ; Eval_tool_selector.Runtime_handler "Tool_masc_agent_dispatch",
      "runtime_handler:Tool_masc_agent_dispatch"
    ; Eval_tool_selector.Eval_tag "agent_profile_lookup", "eval_tag:agent_profile_lookup"
    ; Eval_tool_selector.Receipt_label ("family", "lookup"), "receipt_label:family=lookup"
    ]
;;

let test_rejects_every_other_shape () =
  List.iter
    (fun (name, raw) ->
      match decodes raw with
      | Error _ -> ()
      | Ok decoded ->
        failf "%s must not decode, got %s" name (Eval_tool_selector.label decoded))
    [ "bare string", {|"tool_execute"|}
    ; "kind key", {|{"kind":"tool_name","value":"tool_execute"}|}
    ; "tool alias", {|{"type":"tool","value":"tool_execute"}|}
    ; "name alias", {|{"type":"name","value":"tool_execute"}|}
    ; "descriptor alias", {|{"type":"descriptor","value":"masc.agent.card"}|}
    ; "handler alias", {|{"type":"handler","value":"Tool_x"}|}
    ; "tag alias", {|{"type":"tag","value":"lookup"}|}
    ; "bare tool_name key", {|{"tool_name":"tool_execute"}|}
    ; "bare descriptor_id key", {|{"descriptor_id":"masc.agent.card"}|}
    ]
;;

let () =
  run
    "eval-tool-selector-boundary"
    [ ( "runtime boundary"
      , [ test_case
            "lib/keeper and lib/runtime do not import Eval_tool_selector"
            `Quick
            test_not_used_by_live_keeper_or_runtime
        ] )
    ; ( "decoder shape"
      , [ test_case
            "accepts the shapes to_yojson writes"
            `Quick
            test_accepts_the_shapes_to_yojson_writes
        ; test_case
            "rejects every other shape"
            `Quick
            test_rejects_every_other_shape
        ] )
    ]
;;
