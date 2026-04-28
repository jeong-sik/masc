(** Integration pin for PR-3 of the [Keeper_cwd_response] series.

    PR-3 wires [Keeper_cwd_response.to_yojson_response] into the
    Docker-route response builders inside [keeper_exec_shell.ml]:

    - [render_docker_process_result] (op=pwd / git_status / git_diff / ...)
    - [op="bash"] runtime branch (5 cwd-echo sites in one match arm)
    - [op="git_log"] runtime branch (1 cwd-echo site under [via=docker])

    All other [cwd] usages in the file are intentionally left
    unchanged:

    - [~fields:] / [~extra:] params to [error_json] / [Log.Keeper.*]
      (operator-facing — host path is what operators ssh into)
    - [keeper_bash] Local-execution branch (after the Docker
      dispatch at lines 765/779; for Local keepers the host path
      IS the keeper-visible path)
    - [op] read-style ops with a [path] field (no [cwd] in
      response Assoc — those echo the input target, separate
      concern)
    - [gh_base] under [op="gh"] — multiple route paths
      (docker / brokered / host) deferred to a follow-up PR

    This test is the source-level guard that pins the wired
    sites. The runtime composition contract is already pinned
    by [test_keeper_cwd_response] (PR-1) and
    [test_keeper_shell_docker_cwd_response] (PR-2). *)

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
      "lib/keeper/keeper_exec_shell.ml"
    ; "../lib/keeper/keeper_exec_shell.ml"
    ; "../../lib/keeper/keeper_exec_shell.ml"
    ]

let count_substring src needle =
  let rec loop i count =
    match Astring.String.find_sub ~start:i ~sub:needle src with
    | None -> count
    | Some j -> loop (j + String.length needle) (count + 1)
  in
  loop 0 0

(* The wiring uses [Keeper_cwd_response.to_yojson_response cwd_response]
   for the dispatcher helper and [cwd_field] (a let-bound
   [to_yojson_response] result reused across the 5 op="bash" sites)
   for the bash arm. Both forms must appear at least once each. *)

let test_render_docker_process_result_uses_cwd_response () =
  match find_source_path () with
  | None -> ()
  | Some path ->
    let src = read_source path in
    check bool
      "render_docker_process_result references Keeper_cwd_response.docker"
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

let test_bash_op_has_runtime_aware_cwd_field () =
  match find_source_path () with
  | None -> ()
  | Some path ->
    let src = read_source path in
    (* The op="bash" arm threads cwd_response via a [cwd_field]
       let-binding that is reused across cached/uncached and
       timeout/success branches. Pinning the binding shape
       prevents accidental revert to literal `String cwd`. *)
    check bool
      "cwd_field let-binding (Keeper_cwd_response result) exists"
      true
      (Astring.String.is_infix ~affix:"let cwd_field" src);
    check bool "cwd_field references to_yojson_response" true
      (Astring.String.is_infix
         ~affix:"Keeper_cwd_response.to_yojson_response cwd_response"
         src);
    (* The bash arm previously had 5 [`String cwd] echo sites; all
       should now read [cwd_field]. We assert at least 4 occurrences
       of [cwd_field] in the response Assoc lists. *)
    let cwd_field_uses = count_substring src "; \"cwd\", cwd_field" in
    check bool
      (Printf.sprintf
         "cwd_field used in >= 4 Assoc lists (found %d)"
         cwd_field_uses)
      true (cwd_field_uses >= 4)

let test_git_log_runtime_branch_uses_cwd_response () =
  match find_source_path () with
  | None -> ()
  | Some path ->
    let src = read_source path in
    (* The git_log runtime branch builds its own cwd_response.
       Verify at least 2 distinct [cwd_response = Keeper_cwd_response.docker]
       constructions in the file (render_docker + git_log; the
       op="bash" arm uses [match turn_sandbox_runtime] form
       which differs). *)
    let docker_ctor_uses =
      count_substring src "Keeper_cwd_response.docker ~host_cwd:cwd"
    in
    check bool
      (Printf.sprintf
         "Keeper_cwd_response.docker constructor used >= 2 times \
          (found %d)"
         docker_ctor_uses)
      true (docker_ctor_uses >= 2)

(* Negative pin: a raw [String cwd] literal must not appear
   in the same Assoc as a [via=docker] tag. For each line
   that contains the cwd-string-literal pattern, scan up to
   12 lines forward for a sibling docker-via line; any match
   is a regression and fails the test with the offending
   line numbers. *)

let test_no_raw_cwd_in_docker_route () =
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
        (* Look forward up to 12 lines for a sibling
           [via, `String "docker"] in the same Assoc. *)
        let upper = min (n - 1) (i + 12) in
        let found_docker_via = ref false in
        for j = i + 1 to upper do
          if
            Astring.String.is_infix
              ~affix:"\"via\", `String \"docker\""
              arr.(j)
          then found_docker_via := true
        done;
        if !found_docker_via then leaks := (i + 1) :: !leaks
      end
    done;
    let leaks = List.rev !leaks in
    if leaks <> [] then
      Alcotest.failf
        "raw (\"cwd\", `String cwd) literal found near a \
         (\"via\", `String \"docker\") site at line(s): %s"
        (String.concat ", " (List.map string_of_int leaks))

let () =
  run "keeper_exec_shell_cwd_response"
    [
      ( "wiring-pins"
      , [
          test_case
            "render_docker_process_result wires Cwd_response"
            `Quick
            test_render_docker_process_result_uses_cwd_response
        ; test_case "op=bash uses runtime-aware cwd_field" `Quick
            test_bash_op_has_runtime_aware_cwd_field
        ; test_case
            "git_log runtime branch wires Cwd_response"
            `Quick test_git_log_runtime_branch_uses_cwd_response
        ] )
    ; ( "no-leak-near-docker-via"
      , [
          test_case
            "no raw (\"cwd\", `String cwd) literal near via=docker"
            `Quick test_no_raw_cwd_in_docker_route
        ] )
    ]
