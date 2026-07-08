let contains_substring ~needle text =
  let needle_len = String.length needle in
  let text_len = String.length text in
  if needle_len = 0
  then true
  else if needle_len > text_len
  then false
  else
    let rec loop i =
      if i + needle_len > text_len
      then false
      else if String.sub text i needle_len = needle
      then true
      else loop (i + 1)
    in
    loop 0
;;

let token_looks_like_shell_glob token =
  String.exists
    (function
      | '*' | '?' -> true
      | _ -> false)
    token
  || (String.contains token '[' && String.contains token ']')
;;

let path_not_found_output text =
  contains_substring ~needle:"No such file or directory" text
  || contains_substring ~needle:"cannot access" text
;;

let glob_prone_file_command executable =
  match Shell_ir_command_shape.normalize_command_name executable with
  | "ls" | "cat" | "head" | "tail" | "wc" | "stat" -> true
  | _ -> false
;;

let directory_and_pattern_of_glob_token token =
  match String.rindex_opt token '/' with
  | None -> ".", token
  | Some 0 -> "/", String.sub token 1 (String.length token - 1)
  | Some idx ->
    ( String.sub token 0 idx
    , String.sub token (idx + 1) (String.length token - idx - 1) )
;;

(* A nonzero exit whose stderr carries an OS-level "not found" signature.
   Shared by the glob-literal and duplicate-argv0 diagnostics: both explain a
   suspect argv SHAPE that only becomes a problem when the command could not
   find its target.  This is an OS error signature, not a domain classifier —
   it narrows advisory hints to the failure mode they describe. *)
let is_path_not_found_failure ~status ~stderr =
  match status with
  | Unix.WEXITED 0 -> false
  | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ ->
    stderr <> "" && path_not_found_output stderr
;;

let matching_glob_stage ir =
  Shell_ir_command_shape.effective_stages ir
  |> List.find_map (fun { Shell_ir_command_shape.bin; args } ->
    if glob_prone_file_command bin
    then
      match List.find_opt token_looks_like_shell_glob args with
      | Some token -> Some token
      | None -> None
    else None)
;;

let glob_literal_failure_fields ~ir ~status ~stderr =
  let stderr = String.trim stderr in
  if not (is_path_not_found_failure ~status ~stderr)
  then []
  else
    match matching_glob_stage ir with
    | None -> []
    | Some token ->
      let dir, pattern = directory_and_pattern_of_glob_token token in
      let hint =
        "Typed Execute uses execve-style argv; shell glob characters in argv \
         are passed literally and are not shell-expanded. For wildcard file \
         discovery, run find with -name or rg --files with -g."
      in
      let find_alt =
        Printf.sprintf
          "Use executable=\"find\" argv=[%S, \"-name\", %S]."
          dir
          pattern
      in
      let rg_alt =
        Printf.sprintf
          "Use executable=\"rg\" argv=[\"--files\", %S, \"-g\", %S]."
          dir
          pattern
      in
      [ "execution_hint", `String hint
      ; "shell_ir_hint", `String hint
      ; "typed_glob_not_expanded", `Bool true
      ; "literal_glob_token", `String token
      ; "alternatives", `List [ `String find_alt; `String rg_alt ]
      ]
;;

(* Typed Execute accepts a leading argv token equal to the executable because it
   CAN be an intentional literal argument (e.g. searching for the string "grep"),
   so the gate does not reject it — see the [duplicate_executable_argv0] case in
   test_keeper_tool_execute_typed_input.  But when such a command fails with a
   path-not-found error it is almost always the execve-style mistake of repeating
   the program name: [{executable="wc"; argv=["wc"]}] runs as [wc wc], and wc
   then tries to open a file literally named "wc".  This diagnoses that failure
   with a self-correction hint WITHOUT rejecting — the intentional-payload design
   is preserved; only the not-found failure signature is narrowed and explained.

   Detection is structural: the first stage whose argv[0] equals its executable.
   The path-not-found gate (shared with the glob diagnostic) avoids hinting on
   intentional same-name commands that simply produced no match. *)
let duplicate_argv0_stage ir =
  Shell_ir_command_shape.effective_stages ir
  |> List.find_map (fun { Shell_ir_command_shape.bin; args } ->
    match args with
    | first :: rest
      when String.trim first = String.trim bin && String.trim bin <> "" ->
      Some (String.trim bin, rest)
    | _ -> None)
;;

let duplicate_argv0_failure_fields ~ir ~status ~stderr =
  let stderr = String.trim stderr in
  if not (is_path_not_found_failure ~status ~stderr)
  then []
  else
    match duplicate_argv0_stage ir with
    | None -> []
    | Some (executable, remainder) ->
      let hint =
        Printf.sprintf
          "argv[0]=%S is identical to the executable, so it ran as a literal \
           argument (typed Execute passes argv verbatim, execve-style; the \
           program name is NOT prepended). If the duplicate was unintended, \
           retry with argv[0] removed."
          executable
      in
      let rewrite =
        Printf.sprintf
          "Rewrite: executable=%S argv=[%s]."
          executable
          (String.concat "; " (List.map (Printf.sprintf "%S") remainder))
      in
      [ "execution_hint", `String hint
      ; "shell_ir_hint", `String hint
      ; "argv0_duplicates_executable", `Bool true
      ; "duplicated_executable", `String executable
      ; "rewrite_suggestion", `String rewrite
      ]
;;
