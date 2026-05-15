open Alcotest

module Types = Ide_annotation_types
module Store = Ide_annotations
module Lsp = Masc_mcp.Lsp_overlay_provider

let route_annotation : Types.annotation =
  { id = "ann-route"
  ; file_path = "lib/keeper/keeper_exec_ide.ml"
  ; line_start = 12
  ; line_end = 14
  ; keeper_id = "sangsu"
  ; kind = Types.Comment
  ; content = "Connect this line to the active review context."
  ; goal_id = Some "goal-ide"
  ; task_id = Some "task-42"
  ; board_post_id = Some "post-1"
  ; comment_id = Some "comment-1"
  ; pr_id = Some "15035"
  ; git_ref = Some "feat/context-lens"
  ; log_id = Some "turn-9"
  ; session_id = Some "sess-9"
  ; operation_id = Some "op-9"
  ; worker_run_id = Some "wr-9"
  ; created_at_ms = 1L
  ; updated_at_ms = 2L
  }
;;

let rec rm_rf path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Sys.readdir path |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path)
    else Sys.remove path
;;

let with_temp_dir f =
  let path = Filename.temp_file "masc-ide-annotations" "" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  Fun.protect ~finally:(fun () -> rm_rf path) (fun () -> f path)
;;

let contains ~needle haystack =
  let needle_len = String.length needle in
  let haystack_len = String.length haystack in
  let rec loop idx =
    idx + needle_len <= haystack_len
    && (String.equal (String.sub haystack idx needle_len) needle || loop (idx + 1))
  in
  needle_len = 0 || loop 0
;;

let check_contains label needle haystack =
  check bool label true (contains ~needle haystack)
;;

let assoc key = function
  | `Assoc fields -> List.assoc_opt key fields
  | _ -> None
;;

let string_field key json =
  match assoc key json with
  | Some (`String value) -> Some value
  | _ -> None
;;

let codelens_title = function
  | `Assoc fields ->
    (match List.assoc_opt "command" fields with
     | Some (`Assoc command) ->
       (match List.assoc_opt "title" command with
        | Some (`String title) -> Some title
        | _ -> None)
     | _ -> None)
  | _ -> None
;;

let hover_value = function
  | `Assoc fields ->
    (match List.assoc_opt "contents" fields with
     | Some contents -> string_field "value" contents
     | None -> None)
  | _ -> None
;;

let test_annotation_json_preserves_route_context () =
  match Types.annotation_of_json (Types.annotation_to_json route_annotation) with
  | Error msg -> fail msg
  | Ok decoded ->
    check (option string) "board post" route_annotation.board_post_id decoded.board_post_id;
    check (option string) "comment" route_annotation.comment_id decoded.comment_id;
    check (option string) "pr" route_annotation.pr_id decoded.pr_id;
    check (option string) "git" route_annotation.git_ref decoded.git_ref;
    check (option string) "log" route_annotation.log_id decoded.log_id;
    check (option string) "session" route_annotation.session_id decoded.session_id;
    check (option string) "operation" route_annotation.operation_id decoded.operation_id;
    check (option string) "worker" route_annotation.worker_run_id decoded.worker_run_id
;;

let test_create_lists_route_context () =
  with_temp_dir (fun base_dir ->
    match
      Store.create
        ~base_dir
        ~keeper_id:"sangsu"
        ~file_path:"lib/keeper/keeper_exec_ide.ml"
        ~line_start:12
        ~line_end:14
        ~kind:Types.Question
        ~content:"Should this trace be attached to the PR review?"
        ~goal_id:"goal-ide"
        ~task_id:"task-42"
        ~board_post_id:"post-1"
        ~comment_id:"comment-1"
        ~pr_id:"15035"
        ~git_ref:"feat/context-lens"
        ~log_id:"turn-9"
        ~session_id:"sess-9"
        ~operation_id:"op-9"
        ~worker_run_id:"wr-9"
        ()
    with
    | Error msg -> fail msg
    | Ok created ->
      check (option string) "created pr" (Some "15035") created.pr_id;
      let filter =
        { Types.file_path = Some "lib/keeper/keeper_exec_ide.ml"
        ; keeper_id = None
        ; goal_id = None
        ; task_id = None
        }
      in
      (match Store.list ~base_dir ~filter with
       | [ listed ] ->
         check string "id" created.id listed.id;
         check (option string) "listed comment" (Some "comment-1") listed.comment_id;
         check (option string) "listed log" (Some "turn-9") listed.log_id
       | rows -> failf "expected one listed annotation, got %d" (List.length rows)))
;;

let test_lsp_overlay_exposes_route_context () =
  Eio_main.run (fun _env ->
    with_temp_dir (fun base_dir ->
    match
      Store.create
        ~base_dir
        ~keeper_id:"sangsu"
        ~file_path:"lib/keeper/keeper_exec_ide.ml"
        ~line_start:12
        ~line_end:14
        ~kind:Types.Question
        ~content:"Should this trace be attached to the PR review?"
        ~goal_id:"goal-ide"
        ~task_id:"task-42"
        ~board_post_id:"post-1"
        ~comment_id:"comment-1"
        ~pr_id:"15035"
        ~git_ref:"feat/context-lens"
        ~log_id:"turn-9"
        ~session_id:"sess-9"
        ~operation_id:"op-9"
        ~worker_run_id:"wr-9"
        ()
    with
    | Error msg -> fail msg
    | Ok _ ->
      Lsp.clear_cache ();
      let codelenses =
        Lsp.codelenses ~base_dir ~file_path:"lib/keeper/keeper_exec_ide.ml"
      in
      (match codelenses with
       | [ codelens ] ->
         let title = Option.value ~default:"" (codelens_title codelens) in
         check_contains "codelens carries PR route" "PR:15035" title;
         check_contains "codelens carries log route" "log:turn-9" title
       | rows -> failf "expected one codelens, got %d" (List.length rows));
      let inlay_hints =
        Lsp.inlay_hints ~base_dir ~file_path:"lib/keeper/keeper_exec_ide.ml"
      in
      (match inlay_hints with
       | [ hint ] ->
         let label = Option.value ~default:"" (string_field "label" hint) in
         let tooltip = Option.value ~default:"" (string_field "tooltip" hint) in
         check_contains "inlay carries task route" "task:task-42" label;
         check_contains "inlay carries telemetry route" "worker:wr-9" label;
         check_contains "inlay tooltip carries comment route" "comment:comment-1" tooltip
       | rows -> failf "expected one inlay hint, got %d" (List.length rows));
      let diagnostics =
        Lsp.diagnostics
          ~base_dir
          ~file_path:"lib/keeper/keeper_exec_ide.ml"
          ~lsp_diagnostics:[]
      in
      (match diagnostics with
       | [ diagnostic ] ->
         let message = Option.value ~default:"" (string_field "message" diagnostic) in
         check_contains "diagnostic carries git route" "git:feat/context-lens" message
       | rows -> failf "expected one diagnostic, got %d" (List.length rows));
      let hover =
        Lsp.enrich_hover
          ~base_dir
          ~file_path:"lib/keeper/keeper_exec_ide.ml"
          ~line:11
          (`Assoc
             [ "contents"
             , `Assoc [ "kind", `String "markdown"; "value", `String "Base hover" ]
             ])
      in
      let value = Option.value ~default:"" (hover_value hover) in
      check_contains "hover carries board route" "board:post-1" value;
      check_contains "hover carries operation route" "op:op-9" value))
;;

let () =
  run
    "ide_annotations"
    [ ( "route_context"
      , [ test_case
            "annotation json preserves route context"
            `Quick
            test_annotation_json_preserves_route_context
        ; test_case "create/list preserves route context" `Quick test_create_lists_route_context
        ; test_case
            "LSP overlays expose route context"
            `Quick
            test_lsp_overlay_exposes_route_context
        ] )
    ]
;;
