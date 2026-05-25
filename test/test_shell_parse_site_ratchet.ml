(* test/test_shell_parse_site_ratchet.ml

   Shell IR Adjacent Surfaces Plan, P12 — "Add source guard for
   [Bash.parse_string], raw [cmd], and direct [Exec_gate.run_argv*]
   call-sites" so new raw shell parse-sites cannot appear silently.

   Pattern — baseline ratchet, mirrors [test_masc_dirname_ssot]. The
   current repository contains many legitimate call-sites of both
   primitives. Cleaning all of them is not the goal here; the goal is
   to freeze the inventory with owner labels, so any later refactor
   that introduces a new unclassified parse- or argv-site fails CI
   instead of drifting in silently.

   Baseline file: [test/shell_parse_site_baseline.txt].
   Each non-blank, non-comment line is

       <relpath>:<line>  # <owner_label>

   where [owner_label] is one of the closed set returned by
   [known_labels] below. Labels encode the role of the site in the
   shell-IR architecture; they are intentionally coarse so that
   structural intent stays visible without re-running this audit per
   commit.

   To refresh the baseline after a real fix (or a refactor that moves
   sites):

       MASC_SHELL_PARSE_SITE_DUMP=1 dune exec \
         test/test_shell_parse_site_ratchet.exe

   The test prints a hint listing baseline entries that no longer
   match any source line, but does not fail on removal — removal is
   the goal. It fails on:

   - A current site whose [file:line] is not in the baseline.
   - A baseline entry whose label is not in [known_labels]. *)

let fail_test msg = failwith msg

let search_root () =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some d -> d
  | None -> Sys.getcwd ()

let drain ic =
  let rec loop acc =
    try loop (input_line ic :: acc)
    with End_of_file -> List.rev acc
  in
  loop []

let rg_matching_files ~pattern ~paths =
  let argv =
    Array.of_list
      ([ "rg"; "--no-messages"; "-l"; "-e"; pattern ]
      @ paths
      @ [ "--glob"; "*.ml" ])
  in
  let lines, _status =
    With_process.with_process_args_in "rg" argv With_process.drain_lines
  in
  lines

(* Comment heuristic mirrors [test_masc_dirname_ssot]. We accept false
   negatives (comments misclassified as code) for the literal "Bash"/
   "Exec_gate" reference cases because the baseline absorbs them, but
   we must not miss real call-sites. *)

let starts_with_trim ~prefix line =
  let t = String.trim line in
  String.length t >= String.length prefix
  && String.sub t 0 (String.length prefix) = prefix

let has_substring_before ~needle ~before line =
  match String.index_opt line before.[0] with
  | None -> false
  | Some before_idx ->
    let nlen = String.length needle in
    let rec scan i =
      if i + nlen > before_idx then false
      else if String.sub line i nlen = needle then true
      else scan (i + 1)
    in
    scan 0

let has_substring_after ~needle ~after line =
  match String.index_opt line after.[0] with
  | None -> false
  | Some after_idx ->
    let nlen = String.length needle in
    let llen = String.length line in
    let rec scan i =
      if i + nlen > llen then false
      else if String.sub line i nlen = needle then true
      else scan (i + 1)
    in
    scan (after_idx + 1)

(* References inside ocamldoc brackets, e.g. [Exec_gate.run_argv*], are
   noise even when the surrounding [(* ... *)] is not on the same
   line. We treat any occurrence wrapped in [ ... ] as a doc reference
   when the line does not also contain an actual call (heuristically:
   the line contains no opening parenthesis after the needle). *)
let looks_like_doc_reference ~needle line =
  let nlen = String.length needle in
  let llen = String.length line in
  let rec find_needle i =
    if i + nlen > llen then None
    else if String.sub line i nlen = needle then Some i
    else find_needle (i + 1)
  in
  match find_needle 0 with
  | None -> false
  | Some idx ->
    let before = String.sub line 0 idx in
    let after = String.sub line (idx + nlen) (llen - idx - nlen) in
    let bracketed =
      String.length before > 0
      && (String.contains before '[' || String.contains before '{')
      && (String.contains after ']' || String.contains after '}')
      && not (String.contains after '(')
    in
    bracketed

let line_is_comment_noise ~needle line =
  starts_with_trim ~prefix:"(*" line
  || starts_with_trim ~prefix:"*)" line
  || starts_with_trim ~prefix:"*" line
  || starts_with_trim ~prefix:"**" line
  || has_substring_before ~needle:"(*" ~before:"B" line
  || has_substring_before ~needle:"(*" ~before:"E" line
  || has_substring_after ~needle:"*)" ~after:"B" line
  || has_substring_after ~needle:"*)" ~after:"E" line
  || looks_like_doc_reference ~needle line

type occ = { file : string; line_no : int; needle : string }

let needle_pat needle =
  (* Match the literal needle anywhere on the line. *)
  Str.regexp_string needle

let occurrences_in_file ~needles file =
  let ic = open_in file in
  let rec loop n acc =
    match input_line ic with
    | line ->
      let hit_needle =
        List.find_opt
          (fun needle ->
            (try
              ignore (Str.search_forward (needle_pat needle) line 0);
              not (line_is_comment_noise ~needle line)
            with Not_found -> false))
          needles
      in
      (match hit_needle with
       | Some needle -> loop (n + 1) ({ file; line_no = n; needle } :: acc)
       | None -> loop (n + 1) acc)
    | exception End_of_file -> List.rev acc
  in
  let out = loop 1 [] in
  close_in ic;
  out

let rel path ~root =
  let rlen = String.length root in
  let plen = String.length path in
  if plen > rlen && String.sub path 0 rlen = root then
    let start = if plen > rlen && path.[rlen] = '/' then rlen + 1 else rlen in
    String.sub path start (plen - start)
  else path

let key occ ~root = Printf.sprintf "%s:%d" (rel occ.file ~root) occ.line_no

(* Sites inside the parser/gate library itself are the *definition*
   sites of the IR; they are explicitly allowed and tagged
   [parser_primary]. The other classifications below are categorical
   call-site labels — coarse on purpose, so structural intent stays
   visible. *)

let path_has ~needle path =
  let nlen = String.length needle in
  let plen = String.length path in
  let rec scan i =
    if i + nlen > plen then false
    else if String.sub path i nlen = needle then true
    else scan (i + 1)
  in
  scan 0

let is_parse_needle needle = needle = "Bash.parse_string"

(* Label per (path, needle). [parser_*] labels apply only to
   [Bash.parse_string] sites; [argv_*] labels only to direct
   [Exec_gate.run_argv*] sites. Misclassifying a module by name is avoided by
   routing on the primitive that is actually called. *)
let classify_path ~needle path =
  if is_parse_needle needle then begin
    if path_has ~needle:"lib/exec/parser/" path
       || path_has ~needle:"lib/exec/command_gate/" path
    then "parser_primary"
    else if path_has ~needle:"lib/spawn.ml" path
    then "exec_core"
    else "parser_consumer"
  end
  else begin
    if path_has ~needle:"lib/coord/" path
       || path_has ~needle:"lib/repo_manager/" path
       || path_has ~needle:"lib/dashboard/" path
    then "argv_coord"
    else if path_has ~needle:"lib/keeper/" path
    then "argv_keeper"
    else if path_has ~needle:"lib/tool_" path
            || path_has ~needle:"lib/local/" path
            || path_has ~needle:"lib/server/" path
            || path_has ~needle:"lib/exec/exec_dispatch" path
            || path_has ~needle:"lib/exec/sandbox_target" path
    then "argv_dispatch"
    else if path_has ~needle:"lib/spawn.ml" path
    then "exec_core"
    else "argv_subsystem"
  end

let known_labels =
  [ "parser_primary"
  ; "parser_consumer"
  ; "exec_core"
  ; "argv_coord"
  ; "argv_keeper"
  ; "argv_dispatch"
  ; "argv_subsystem"
  ]

(* Test files inside lib/ (e.g. lib/exec/test/) are not surfaces we
   intend to ratchet; their job is to exercise the parser. *)
let is_excluded_path relp =
  path_has ~needle:"/test/" relp
  || (String.length relp >= 5 && String.sub relp 0 5 = "test/")

let read_baseline path =
  if not (Sys.file_exists path) then []
  else begin
    let ic = open_in path in
    let out = drain ic in
    close_in ic;
    List.filter_map
      (fun raw ->
        let s = String.trim raw in
        if s = "" then None
        else if String.length s >= 1 && s.[0] = '#' then None
        else
          match String.index_opt s '#' with
          | None -> Some (s, "")
          | Some idx ->
            let site = String.trim (String.sub s 0 idx) in
            let label =
              String.trim (String.sub s (idx + 1) (String.length s - idx - 1))
            in
            if site = "" then None else Some (site, label))
      out
  end

let write_baseline path entries =
  let oc = open_out path in
  output_string oc
    "# Shell parse-site ratchet baseline (P12). Format:\n\
     #   <relpath>:<line>  # <owner_label>\n\
     # Refresh: MASC_SHELL_PARSE_SITE_DUMP=1 dune exec test/test_shell_parse_site_ratchet.exe\n\
     # Labels — closed set documented in test/test_shell_parse_site_ratchet.ml\n";
  List.iter
    (fun (site, label) ->
      output_string oc site;
      output_string oc "  # ";
      output_string oc label;
      output_char oc '\n')
    entries;
  close_out oc

let () =
  let root = search_root () in
  let lib_dir = Filename.concat root "lib" in
  let baseline_path =
    Filename.concat root "test/shell_parse_site_baseline.txt"
  in
  (* Two needles — primary parser entry and direct argv runner.
     [Bash.parse_string] catches both [Bash.parse_string] and the
     fully-qualified [Masc_exec_bash_parser.Bash.parse_string].
     [Exec_gate.run_argv] catches every overload. *)
  let needles = [ "Bash.parse_string"; "Exec_gate.run_argv" ] in
  let candidate_files =
    List.sort_uniq String.compare
      (List.concat_map
         (fun n -> rg_matching_files ~pattern:n ~paths:[ lib_dir ])
         needles)
  in
  let current_sites =
    List.concat_map
      (fun abs_path ->
        let relp = rel abs_path ~root in
        if is_excluded_path relp then []
        else
          List.map
            (fun occ ->
              ( key occ ~root
              , classify_path ~needle:occ.needle (rel occ.file ~root) ))
            (occurrences_in_file ~needles abs_path))
      candidate_files
    |> List.sort_uniq compare
  in
  let dump_mode =
    match Sys.getenv_opt "MASC_SHELL_PARSE_SITE_DUMP" with
    | Some v when v <> "" && v <> "0" -> true
    | _ -> false
  in
  if dump_mode then begin
    write_baseline baseline_path current_sites;
    Printf.printf
      "test_shell_parse_site_ratchet: wrote %d baseline entries to %s\n"
      (List.length current_sites) baseline_path
  end
  else begin
    let baseline = read_baseline baseline_path in
    let baseline_keys =
      List.map (fun (s, _l) -> s) baseline |> List.sort_uniq String.compare
    in
    let current_keys =
      List.map (fun (s, _l) -> s) current_sites |> List.sort_uniq String.compare
    in
    let new_violations =
      List.filter (fun k -> not (List.mem k baseline_keys)) current_keys
    in
    let removed =
      List.filter (fun k -> not (List.mem k current_keys)) baseline_keys
    in
    let unknown_labels =
      List.filter_map
        (fun (site, label) ->
          if label = "" then Some (site, "<missing>")
          else if List.mem label known_labels then None
          else Some (site, label))
        baseline
    in
    if unknown_labels <> [] then
      fail_test
        (Printf.sprintf
           "\nP12 ratchet: %d baseline entry/ies use an unknown owner label.\n\
            Known labels: %s.\n\
            Offending entries:\n  %s\n"
           (List.length unknown_labels)
           (String.concat ", " known_labels)
           (String.concat "\n  "
              (List.map (fun (s, l) -> s ^ " [" ^ l ^ "]") unknown_labels)));
    if new_violations <> [] then
      fail_test
        (Printf.sprintf
           "\nP12 ratchet violated — %d new Bash.parse_string / Exec_gate.run_argv \
            call-site(s) appeared in lib/ outside the baseline.\n\
            A new raw shell parse- or argv-site needs an explicit owner. If \
            this is intended, refresh the baseline:\n\
              MASC_SHELL_PARSE_SITE_DUMP=1 dune exec test/test_shell_parse_site_ratchet.exe\n\
            and route the site through a typed adapter (Shell IR, structured \
            argv wrapper, or descriptor) — see lib/exec_shell_adapter.ml and \
            Shell IR plan §P10/P11. New entries:\n  %s\n"
           (List.length new_violations)
           (String.concat "\n  " new_violations));
    if removed <> [] then
      Printf.printf
        "test_shell_parse_site_ratchet: note — %d baseline entry/ies no longer match \
         any source line; run MASC_SHELL_PARSE_SITE_DUMP=1 to refresh the \
         baseline:\n  %s\n"
        (List.length removed) (String.concat "\n  " removed);
    Printf.printf
      "test_shell_parse_site_ratchet: OK (current=%d, baseline=%d)\n"
      (List.length current_keys) (List.length baseline_keys)
  end
