(* Env knob catalog generator.

   Scans lib/config/env_config_*.ml and emits a markdown catalog of every
   declared MASC_* environment variable, with the surrounding doc-comment
   (if any) and the call shape (typed accessor or feature flag).

   This addresses #10733 (env knob proliferation 410+ knobs uncategorized).
   The catalog is not a refactor — it surfaces the existing surface area
   in one mechanically derived document so operators can see ops-class
   knobs without grepping. CI runs this and fails on drift.

   Out-of-scope here: tagging knobs with @category Timeouts | Concurrency |
   Thresholds | Policies. That is a follow-up. The catalog is the prereq.

   Design: regex-line scan, not full OCaml parse. The env_config_*.ml files
   follow a stylistically uniform convention which makes line-scan reliable
   for the 9 shapes that exist today. If a future shape is added, this
   tool emits an "Unrecognized" entry and CI will surface it. *)

let env_var_re = Str.regexp "\"\\(MASC_[A-Z][A-Z0-9_]*\\)\""

let typed_get_re =
  Str.regexp "get_\\(int\\|int_nonneg\\|float\\|float_nonneg\\|float_in_range\\|ratio\\|string\\|bool\\)"

let feature_flag_re = Str.regexp "Feature_flag_registry\\.get_bool"
let entry_env_re = Str.regexp "entry_env_overridable[ \t]+~env_var:"

type kind = Typed_get of string | Feature_flag | Entry_env | String_lit

let kind_to_string = function
  | Typed_get tag -> "typed:" ^ tag
  | Feature_flag -> "feature_flag"
  | Entry_env -> "entry_env_overridable"
  | String_lit -> "string_literal"

type entry = {
  file : string;
  line : int;
  env_var : string;
  kind : kind;
  doc : string option;
}

let read_lines path =
  let ic = open_in path in
  let buf = ref [] in
  (try
     while true do
       buf := input_line ic :: !buf
     done
   with End_of_file -> ());
  close_in ic;
  List.rev !buf

let starts_with s prefix =
  String.length s >= String.length prefix
  && String.sub s 0 (String.length prefix) = prefix

let ends_with s suffix =
  let ls = String.length s and lp = String.length suffix in
  ls >= lp && String.sub s (ls - lp) lp = suffix

(* Collect the nearest preceding [(** ... *)] doc block, walking past
   intervening binding lines (e.g. [let foo =], match heads). Looks back
   up to 6 non-blank lines so we tolerate the common shape:

       (** doc *)
       let foo =
         get_int ~default:N "MASC_FOO"
*)
let doc_above arr target_idx =
  let max_lookback = 8 in
  (* Find the line where doc block ends, walking past non-doc bindings. *)
  let rec find_doc_end idx steps =
    if idx < 0 || steps >= max_lookback then None
    else
      let line = String.trim arr.(idx) in
      if line = "" then find_doc_end (idx - 1) (steps + 1)
      else if ends_with line "*)" then Some idx
      else if starts_with line "let " || starts_with line "and "
              || starts_with line "(* " || starts_with line "in"
              || starts_with line "|" || starts_with line "match "
              || starts_with line "with " || starts_with line "module "
              || ends_with line "=" then
        find_doc_end (idx - 1) (steps + 1)
      else None
  in
  match find_doc_end (target_idx - 1) 0 with
  | None -> None
  | Some end_idx ->
    (* Walk backwards from end_idx to find the doc-block opener. *)
    let rec find_start idx =
      if idx < 0 then None
      else
        let line = String.trim arr.(idx) in
        if starts_with line "(**" then Some idx
        else if ends_with line "*)" && idx <> end_idx then None
        else find_start (idx - 1)
    in
    (match find_start end_idx with
     | None -> None
     | Some start_idx ->
       let parts = ref [] in
       for j = start_idx to end_idx do
         let raw = String.trim arr.(j) in
         let t =
           if starts_with raw "(**" then
             String.trim (String.sub raw 3 (String.length raw - 3))
           else if starts_with raw "*" && not (starts_with raw "*)") then
             String.trim (String.sub raw 1 (String.length raw - 1))
           else raw
         in
         let t =
           if ends_with t "*)" then
             String.trim (String.sub t 0 (String.length t - 2))
           else t
         in
         if t <> "" then parts := t :: !parts
       done;
       let joined = List.rev !parts |> String.concat " " in
       if joined = "" then None else Some joined)

let try_search re line =
  try
    let _ = Str.search_forward re line 0 in
    true
  with Not_found -> false

let classify_line line =
  if try_search feature_flag_re line then Some Feature_flag
  else if try_search entry_env_re line then Some Entry_env
  else if try_search typed_get_re line then
    let tag = try Str.matched_group 1 line with Not_found | Invalid_argument _ -> "?" in
    Some (Typed_get tag)
  else None

let scan_file path =
  let lines = read_lines path in
  let arr = Array.of_list lines in
  let acc = ref [] in
  Array.iteri
    (fun i line ->
      let pos = ref 0 in
      try
        while !pos < String.length line do
          let _ = Str.search_forward env_var_re line !pos in
          (* Capture all Str-based info up front — subsequent Str calls
             (in classify_line) clobber the global match state. *)
          let env_var = Str.matched_group 1 line in
          let next_pos = Str.match_end () in
          (* The typed accessor / feature flag may be on a line above
             (continuation form). Look at this line and up to 2 lines
             above for the call shape. *)
          let kind =
            let rec try_classify offset =
              if offset > 2 || i - offset < 0 then String_lit
              else
                match classify_line arr.(i - offset) with
                | Some k -> k
                | None -> try_classify (offset + 1)
            in
            try_classify 0
          in
          let doc = doc_above arr i in
          acc :=
            {
              file = path;
              line = i + 1;
              env_var;
              kind;
              doc;
            }
            :: !acc;
          pos := next_pos
        done
      with Not_found -> ())
    arr;
  List.rev !acc

let collect_files dir =
  Sys.readdir dir
  |> Array.to_list
  |> List.filter (fun f ->
         let prefix_ok =
           String.length f >= 11 && String.sub f 0 11 = "env_config_"
         in
         let ext_ok =
           String.length f >= 3
           && String.sub f (String.length f - 3) 3 = ".ml"
         in
         prefix_ok && ext_ok)
  |> List.map (fun f -> Filename.concat dir f)
  |> List.sort compare

let module_of_path path =
  let base = Filename.basename path in
  let name = Filename.remove_extension base in
  String.capitalize_ascii name

(* Group entries by env_var keeping the first (highest-precedence) site
   so the catalog has one row per knob instead of one row per reference. *)
let dedupe entries =
  let tbl = Hashtbl.create 256 in
  List.iter
    (fun e ->
      if not (Hashtbl.mem tbl e.env_var) then Hashtbl.add tbl e.env_var e
      else
        match Hashtbl.find tbl e.env_var with
        | existing
          when (match existing.kind with String_lit -> true | _ -> false)
               && (match e.kind with String_lit -> false | _ -> true) ->
            Hashtbl.replace tbl e.env_var e
        | _ -> ())
    entries;
  Hashtbl.fold (fun _ v acc -> v :: acc) tbl []
  |> List.sort (fun a b -> compare a.env_var b.env_var)

let escape_md s =
  let buf = Buffer.create (String.length s) in
  String.iter
    (fun c ->
      match c with
      | '|' -> Buffer.add_string buf "\\|"
      | '\n' -> Buffer.add_char buf ' '
      | _ -> Buffer.add_char buf c)
    s;
  Buffer.contents buf

let truncate_doc s =
  let s = String.trim s in
  if String.length s <= 120 then s
  else String.sub s 0 117 ^ "..."

let render entries =
  let buf = Buffer.create 65536 in
  Buffer.add_string buf
    "# Runtime Tunables Catalog\n\
     \n\
     <!-- AUTO-GENERATED by bin/env_knob_catalog.ml. Do not edit by hand.\n\
     \    Regenerate: dune exec ./bin/env_knob_catalog.exe -- \
     docs/runtime-tunables.md\n\
     \    Source: lib/config/env_config_*.ml -->\n\
     \n\
     This file is mechanically derived from `lib/config/env_config_*.ml`.\n\
     CI fails on drift (`Env knob catalog drift gate`). To add a new\n\
     `MASC_*` env var, declare it in the appropriate `env_config_*.ml`\n\
     module and regenerate this file.\n\
     \n\
     See [#10733](https://github.com/jeong-sik/masc-mcp/issues/10733) for\n\
     the categorization roadmap (`@category` tags are a follow-up).\n\
     \n";
  let by_module = Hashtbl.create 16 in
  List.iter
    (fun e ->
      let key = module_of_path e.file in
      let cur = try Hashtbl.find by_module key with Not_found -> [] in
      Hashtbl.replace by_module key (e :: cur))
    entries;
  let modules =
    Hashtbl.fold (fun k _ acc -> k :: acc) by_module [] |> List.sort compare
  in
  Buffer.add_string buf
    (Printf.sprintf "**Total**: %d unique knobs across %d modules.\n\n"
       (List.length entries) (List.length modules));
  List.iter
    (fun m ->
      let module_entries =
        Hashtbl.find by_module m |> List.sort (fun a b -> compare a.env_var b.env_var)
      in
      Buffer.add_string buf
        (Printf.sprintf "## %s (%d knobs)\n\n" m (List.length module_entries));
      Buffer.add_string buf
        "| Env var | Kind | Line | Doc |\n|---|---|---|---|\n";
      List.iter
        (fun e ->
          let doc =
            match e.doc with Some d -> truncate_doc d |> escape_md | None -> ""
          in
          Buffer.add_string buf
            (Printf.sprintf "| `%s` | %s | %d | %s |\n" e.env_var
               (kind_to_string e.kind) e.line doc))
        module_entries;
      Buffer.add_char buf '\n')
    modules;
  Buffer.contents buf

let usage () =
  prerr_endline "usage: env_knob_catalog.exe <output-md-path> [--lib-dir DIR]";
  exit 2

let parse_args () =
  let argv = Array.to_list Sys.argv in
  match argv with
  | [ _; out ] -> (out, "lib/config")
  | [ _; out; "--lib-dir"; dir ] -> (out, dir)
  | _ -> usage ()

let () =
  let out_path, lib_dir = parse_args () in
  if not (Sys.file_exists lib_dir) then begin
    prerr_endline (Printf.sprintf "lib-dir not found: %s" lib_dir);
    exit 1
  end;
  let files = collect_files lib_dir in
  let entries = List.concat_map scan_file files |> dedupe in
  let md = render entries in
  let oc = open_out out_path in
  output_string oc md;
  close_out oc;
  Printf.printf "wrote %s (entries=%d files=%d)\n" out_path
    (List.length entries) (List.length files)
