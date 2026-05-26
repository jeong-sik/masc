(** Integration pin for PR-3 of the [Keeper_cwd_response] series.

    PR-3 wires [Keeper_cwd_response.to_yojson_response] into the
    sandbox-backend response builders inside [keeper_shell_read_ops.ml]:

    - [render_sandbox_process_result] (op=pwd / git_status / git_log / ...)
    - [op="git_log"] runtime branch (1 cwd-echo site under backend [via])

    All other [cwd] usages in the file are intentionally left
    unchanged:

    - [~fields:] / [~extra:] params to [error_json] / [Log.Keeper.*]
      (operator-facing — host path is what operators ssh into)
    - [tool_execute] Local-execution branch in [keeper_shell_bash.ml];
      for Local keepers the host path IS the keeper-visible path
    - [op] read-style ops with a [path] field (no [cwd] in
      response Assoc — those echo the input target, separate
      concern)
    This test is the source-level guard that pins the wired
    sites. The runtime composition contract is already pinned
    by [test_keeper_cwd_response] (PR-1) and
    [test_keeper_sandbox_docker_cwd_response] (PR-2). *)

open Alcotest

let read_source path =
  let ic = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () ->
      let buf = Buffer.create 16384 in
      (try
         while true do
           Buffer.add_string buf (input_line ic);
           Buffer.add_char buf '\n'
         done
       with End_of_file -> ());
      Buffer.contents buf)

let find_source_path () =
  List.find_opt Sys.file_exists
    [
      "lib/keeper/keeper_shell_read_ops.ml"
    ; "../lib/keeper/keeper_shell_read_ops.ml"
    ; "../../lib/keeper/keeper_shell_read_ops.ml"
    ]

let count_substring src needle =
  let rec loop i count =
    match Astring.String.find_sub ~start:i ~sub:needle src with
    | None -> count
    | Some j -> loop (j + String.length needle) (count + 1)
  in
  loop 0 0

(* The wiring uses [Keeper_cwd_response.to_yojson_response cwd_response]
   for the dispatcher helper. Generic op=bash has been removed from
   tool_workspace_inspect, so there should no longer be a separate bash cwd echo path. *)

let test_render_sandbox_process_result_uses_cwd_response () =
  match find_source_path () with
  | None -> ()
  | Some path ->
    let src = read_source path in
    check bool
      "render_sandbox_process_result references Keeper_cwd_response.docker"
      true
      (Astring.String.is_infix
         ~affix:"Keeper_cwd_response.docker ~host_cwd:cwd"
         src);
    check bool
      "Keeper_cwd_response.to_yojson_response is referenced \
       (rendering uses it)"
      true
      (Astring.String.is_infix
         ~affix:"Keeper_cwd_response.to_yojson_response"
         src)

let test_bash_op_has_no_special_runtime_branch () =
  match find_source_path () with
  | None -> ()
  | Some path ->
    let src = read_source path in
    check bool "legacy op=bash branch removed" false
      (Astring.String.is_infix ~affix:"| \"bash\" ->" src);
    check bool "legacy op=bash cwd_field absent" false
      (Astring.String.is_infix ~affix:"let cwd_field" src)

let test_git_log_runtime_branch_uses_cwd_response () =
  match find_source_path () with
  | None -> ()
  | Some path ->
    let src = read_source path in
    (* The git_log runtime branch builds its own cwd_response.
       Verify at least 2 distinct [cwd_response = Keeper_cwd_response.docker]
       constructions in the file (render_sandbox + git_log; the
       generic op=bash branch was removed and now falls through the
       unsupported-op response, so it no longer constructs cwd responses). *)
    let docker_ctor_uses =
      count_substring src "Keeper_cwd_response.docker ~host_cwd:cwd"
    in
    check bool
      (Printf.sprintf
         "Keeper_cwd_response.docker constructor used >= 2 times \
          (found %d)"
         docker_ctor_uses)
      true (docker_ctor_uses >= 2)

let is_backend_via_line line =
  Astring.String.is_infix
    ~affix:"\"via\", `String Keeper_sandbox_read_runner.backend_via"
    line
  || Astring.String.is_infix ~affix:"\"via\", `String \"docker\"" line

(* Negative pin: a raw [String cwd] literal must not appear
   in the same Assoc as a sandbox backend [via] tag. For each line
   that contains the cwd-string-literal pattern, scan up to
   12 lines forward for a sibling backend-via line; any match
   is a regression and fails the test with the offending
   line numbers. *)

let test_no_raw_cwd_in_backend_route () =
  match find_source_path () with
  | None -> ()
  | Some path ->
    let src = read_source path in
    let lines = String.split_on_char '\n' src in
    let arr = Array.of_list lines in
    let n = Array.length arr in
    let leaks = ref [] in
    for i = 0 to n - 1 do
      if
        Astring.String.is_infix ~affix:"\"cwd\", `String cwd"
          arr.(i)
      then begin
        (* Look forward up to 12 lines for a sibling backend [via] in the
           same Assoc. *)
        let upper = min (n - 1) (i + 12) in
        let found_backend_via = ref false in
        for j = i + 1 to upper do
          if is_backend_via_line arr.(j) then found_backend_via := true
        done;
        if !found_backend_via then leaks := (i + 1) :: !leaks
      end
    done;
    let leaks = List.rev !leaks in
    if leaks <> [] then
      Alcotest.failf
        "raw (\"cwd\", `String cwd) literal found near a \
         backend-via site at line(s): %s"
        (String.concat ", " (List.map string_of_int leaks))

let () =
  run "keeper_exec_shell_cwd_response"
    [
      ( "wiring-pins"
      , [
          test_case
            "render_sandbox_process_result wires Cwd_response"
            `Quick
            test_render_sandbox_process_result_uses_cwd_response
        ; test_case "op=bash has no special runtime branch" `Quick
            test_bash_op_has_no_special_runtime_branch
        ; test_case
            "git_log runtime branch wires Cwd_response"
            `Quick test_git_log_runtime_branch_uses_cwd_response
        ] )
    ; ( "no-leak-near-backend-via"
      , [
          test_case
            "no raw (\"cwd\", `String cwd) literal near backend via"
            `Quick test_no_raw_cwd_in_backend_route
        ] )
    ]
