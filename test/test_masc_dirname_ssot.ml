(* test/test_masc_dirname_ssot.ml

   #9571 SSOT enforcement: outside the SSOT module, [lib/] and [bin/]
   must not add new inline [".masc"] literals. Instead route through
   [Common.masc_dirname] or [Common.masc_dir_from_base_path].

   Strategy — **baseline ratchet**. The current repository already
   carries ~45 such occurrences, many of them in docstrings and a few
   in legitimate code paths. Cleaning all of them in one PR would be
   noise. The canonical industry pattern for legacy cleanup is a
   baseline snapshot: freeze current state in a tracked file, assert
   [current violations] is a subset of [baseline], and ratchet the
   baseline down as fixes land. Prior art: Jane Street [expect-test],
   Facebook [retest] baselines, Google's "golden files" for legacy
   lint cleanups.

   The baseline lives at [test/masc_dirname_ssot_baseline.txt] (one
   [file:line] per line, sorted). To update after a real fix:
     MASC_DIRNAME_SSOT_DUMP=1 dune exec test/test_masc_dirname_ssot.exe
   regenerates the file in place.

   If the test fails with a non-empty "new violations" list, a new
   call site inlined [".masc"] where it should not have. The fix is
   structural: route through [Common.masc_dir_from_base_path]. *)

let fail_test msg = failwith msg

let search_root () =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some d -> d
  | None -> Sys.getcwd ()
;;

let drain ic =
  let rec loop acc =
    try loop (input_line ic :: acc) with
    | End_of_file -> List.rev acc
  in
  loop []
;;

let rg_matching_files ~pattern ~paths =
  let paths_quoted = String.concat " " (List.map Filename.quote paths) in
  let cmd =
    Printf.sprintf
      "rg --no-messages -l -e %s %s --glob '*.ml' --glob '*.mli' || true"
      (Filename.quote pattern)
      paths_quoted
  in
  let ic = Unix.open_process_in cmd in
  let lines = drain ic in
  let _ = Unix.close_process_in ic in
  lines
;;

(* Heuristic: skip occurrences whose line is clearly inside an OCaml
   comment. OCaml block comments can span multiple lines, but for the
   purposes of this ratchet we accept false negatives (i.e. a comment
   misclassified as code) — the baseline handles those. What we MUST
   NOT do is miss real code bypasses.

   Rules:
   - Trimmed line starts with an OCaml comment opener or continuation.
   - Line contains an OCaml comment opener before the literal column -
     inline comment scope (the literal is inside). *)

let starts_with_trim ~prefix line =
  let t = String.trim line in
  String.length t >= String.length prefix
  && String.sub t 0 (String.length prefix) = prefix
;;

let has_substring_before ~needle ~before line =
  match String.index_opt line before.[0] with
  | None -> false
  | Some before_idx ->
    (* Check if [needle] appears at or before [before_idx]. *)
    let nlen = String.length needle in
    let rec scan i =
      if i + nlen > before_idx
      then false
      else if String.sub line i nlen = needle
      then true
      else scan (i + 1)
    in
    scan 0
;;

(* True when [needle] appears AFTER the first ['"'] column in [line].
   Used to detect a multi-line block comment whose closer appears on
   the same line as the tolerated literal. *)
let has_substring_after ~needle ~after line =
  match String.index_opt line after.[0] with
  | None -> false
  | Some after_idx ->
    let nlen = String.length needle in
    let llen = String.length line in
    let rec scan i =
      if i + nlen > llen
      then false
      else if String.sub line i nlen = needle
      then true
      else scan (i + 1)
    in
    scan (after_idx + 1)
;;

let line_is_comment_noise line =
  starts_with_trim ~prefix:"(*" line
  || starts_with_trim ~prefix:"*)" line
  || starts_with_trim ~prefix:"*" line
  || starts_with_trim ~prefix:"**" line
  (* literal preceded by "(*" on the same line *)
  || has_substring_before ~needle:"(*" ~before:"\"" line
  (* literal inside a multi-line block comment whose closer appears
     after the literal on the same line. *)
  || has_substring_after ~needle:"*)" ~after:"\"" line
;;

type occ =
  { file : string
  ; line_no : int
  }

let literal_occurrences_in_file file =
  let ic = open_in file in
  let rec loop n acc =
    match input_line ic with
    | line ->
      let has_literal =
        try
          ignore (Str.search_forward (Str.regexp_string "\".masc\"") line 0);
          true
        with
        | Not_found ->
          (try
             ignore (Str.search_forward (Str.regexp_string "\".masc/") line 0);
             true
           with
           | Not_found -> false)
      in
      if has_literal && not (line_is_comment_noise line)
      then loop (n + 1) ({ file; line_no = n } :: acc)
      else loop (n + 1) acc
    | exception End_of_file -> List.rev acc
  in
  let out = loop 1 [] in
  close_in ic;
  out
;;

let rel path ~root =
  let rlen = String.length root in
  let plen = String.length path in
  if plen > rlen && String.sub path 0 rlen = root
  then (
    let start = if plen > rlen && path.[rlen] = '/' then rlen + 1 else rlen in
    String.sub path start (plen - start))
  else path
;;

let key occ ~root = Printf.sprintf "%s:%d" (rel occ.file ~root) occ.line_no

(* The SSOT module itself is permitted — it is the definition. *)
let is_ssot_module path = path = "lib/core/common.ml" || path = "lib/core/common.mli"

let read_baseline path =
  if not (Sys.file_exists path)
  then []
  else (
    let ic = open_in path in
    let out = drain ic in
    close_in ic;
    List.filter (fun s -> String.trim s <> "") out)
;;

let write_baseline path entries =
  let oc = open_out path in
  List.iter
    (fun e ->
       output_string oc e;
       output_char oc '\n')
    entries;
  close_out oc
;;

let () =
  let root = search_root () in
  let lib_dir = Filename.concat root "lib" in
  let bin_dir = Filename.concat root "bin" in
  let baseline_path = Filename.concat root "test/masc_dirname_ssot_baseline.txt" in
  let candidate_files =
    rg_matching_files ~pattern:"\\.masc" ~paths:[ lib_dir; bin_dir ]
  in
  let current_keys =
    List.concat_map
      (fun abs_path ->
         let relp = rel abs_path ~root in
         if is_ssot_module relp
         then []
         else List.map (fun occ -> key occ ~root) (literal_occurrences_in_file abs_path))
      candidate_files
    |> List.sort_uniq String.compare
  in
  let dump_mode =
    match Sys.getenv_opt "MASC_DIRNAME_SSOT_DUMP" with
    | Some v when v <> "" && v <> "0" -> true
    | _ -> false
  in
  if dump_mode
  then (
    write_baseline baseline_path current_keys;
    Printf.printf
      "test_masc_dirname_ssot: wrote %d baseline entries to %s\n"
      (List.length current_keys)
      baseline_path)
  else (
    let baseline = read_baseline baseline_path in
    let baseline_set =
      List.fold_left
        (fun acc k ->
           let t = String.trim k in
           if t = "" then acc else t :: acc)
        []
        baseline
      |> List.sort_uniq String.compare
    in
    let new_violations =
      List.filter (fun k -> not (List.mem k baseline_set)) current_keys
    in
    let removed = List.filter (fun k -> not (List.mem k current_keys)) baseline_set in
    if new_violations <> []
    then
      fail_test
        (Printf.sprintf
           "\n\
            #9571 SSOT ratchet violated — %d new inline \".masc\" literal(s) appeared \
            outside Common.masc_dirname. Route through Common.masc_dir_from_base_path \
            or, if the site is a docstring, extend [line_is_comment_noise] in the test. \
            New entries:\n\
           \  %s"
           (List.length new_violations)
           (String.concat "\n  " new_violations));
    if removed <> []
    then
      Printf.printf
        "test_masc_dirname_ssot: note — %d baseline entry/ies no longer match any source \
         line; run MASC_DIRNAME_SSOT_DUMP=1 to refresh the baseline:\n\
        \  %s\n"
        (List.length removed)
        (String.concat "\n  " removed);
    Printf.printf
      "test_masc_dirname_ssot: OK (current=%d, baseline=%d)\n"
      (List.length current_keys)
      (List.length baseline_set))
;;
