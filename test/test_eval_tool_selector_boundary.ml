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

let contains_substring ~needle text =
  let nlen = String.length needle in
  let tlen = String.length text in
  let rec loop i =
    if i + nlen > tlen
    then false
    else if String.sub text i nlen = needle
    then true
    else loop (i + 1)
  in
  loop 0
;;

let test_not_used_by_live_keeper_or_runtime () =
  let files = List.fold_left (fun acc root -> collect_sources root acc) [] guarded_roots in
  let offenders =
    files
    |> List.filter (fun path ->
      contains_substring ~needle:"Eval_tool_selector" (read_file path))
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

let () =
  run
    "eval-tool-selector-boundary"
    [ ( "runtime boundary"
      , [ test_case
            "lib/keeper and lib/runtime do not import Eval_tool_selector"
            `Quick
            test_not_used_by_live_keeper_or_runtime
        ] )
    ]
;;
