(* RFC-0071 §3.2 codemod scaffold (PR-1).

   Standalone executable. Reads typed-AST [.cmt] files produced by
   [dune build @check] and (in subsequent PRs) walks [Typedtree] for
   fragile-match catch-all sites on closed concrete variants.

   Scope of THIS scaffold:
   - CLI: --root <dir> --out <diff-dir> [--check]
   - .cmt discovery + load (Cmt_format.read_cmt)
   - Smoke pass: count loaded .cmt files, no AST walk yet.

   Subsequent PRs (RFC-0071 §3.2 WS-3 plan):
     PR-2 scanner   — Texp_match traversal + scrutinee type resolution
     PR-3 triage    — (a)/(b)/(c) classification per §3.4.1
     PR-4 rewriter  — unified diff generation, grouped by (file, type)
     PR-5 idempotency — §5.1 re-apply assertion, inventory backfill *)

(* CLI flags (RFC-0071 §3.2). *)
type mode = Generate_diffs | Check_idempotent

let usage =
  "Usage: exhaustive_codemod --root <repo-root> --out <diff-dir> [--check]\n\
  \  --root DIR    Repository root (contains _build/).\n\
  \  --out  DIR    Output directory for unified diffs.\n\
  \  --check       Idempotency mode: assert no further diff (RFC-0071 §5.1).\n"

let parse_args () =
  let root = ref "" in
  let out = ref "" in
  let mode = ref Generate_diffs in
  let specs =
    [ ("--root", Arg.Set_string root, " Repository root")
    ; ("--out", Arg.Set_string out, " Diff output directory")
    ; ("--check", Arg.Unit (fun () -> mode := Check_idempotent),
        " Idempotency mode (RFC-0071 §5.1)")
    ]
  in
  Arg.parse specs (fun arg ->
    prerr_endline ("Unexpected argument: " ^ arg);
    prerr_endline usage;
    exit 2
  ) usage;
  if !root = "" then begin
    prerr_endline "error: --root is required";
    prerr_endline usage;
    exit 2
  end;
  (!root, !out, !mode)

(* .cmt discovery — walk root/_build/default/lib/ recursively. *)
let rec find_cmt_files dir acc =
  match Sys.readdir dir with
  | exception Sys_error _ -> acc
  | entries ->
    Array.fold_left (fun acc name ->
      let path = Filename.concat dir name in
      match (Unix.lstat path).st_kind with
      | Unix.S_DIR -> find_cmt_files path acc
      | Unix.S_REG when Filename.check_suffix name ".cmt" -> path :: acc
      | _ -> acc
      | exception Unix.Unix_error _ -> acc
    ) acc entries

(* Exclusions (RFC-0071 §3.2): Menhir parser is generated, tests are
   out of scope for codemod. *)
let is_excluded path =
  let contains needle =
    try ignore (Str.search_forward (Str.regexp_string needle) path 0); true
    with Not_found -> false
  in
  contains "/lib/exec/parser/" || contains "/test/"

(* Load one .cmt; return None on parse failure (e.g. non-cmt file or
   corrupt). PR-2 will surface this list to the scanner. *)
let load_cmt path : Cmt_format.cmt_infos option =
  try
    let _, cmt = Cmt_format.read path in
    cmt
  with _ -> None

let run_generate root out =
  let lib_build = Filename.concat root "_build/default/lib" in
  if not (Sys.file_exists lib_build) then begin
    Printf.eprintf
      "error: %s not found. Run `dune build @check` first.\n" lib_build;
    exit 1
  end;
  let cmt_files =
    find_cmt_files lib_build []
    |> List.filter (fun p -> not (is_excluded p))
  in
  let loaded = List.filter_map (fun p ->
    match load_cmt p with
    | Some info -> Some (p, info)
    | None -> None
  ) cmt_files in
  Printf.printf
    "exhaustive_codemod scaffold: discovered=%d, loaded=%d (out=%s).\n"
    (List.length cmt_files) (List.length loaded) out;
  (* Scanner output lands here in PR-2. *)
  ()

let run_check () =
  (* PR-5 fills this in: re-apply diffs, assert empty result. *)
  Printf.printf
    "exhaustive_codemod --check: not yet implemented (RFC-0071 §5.1, PR-5).\n";
  exit 0

let () =
  let (root, out, mode) = parse_args () in
  match mode with
  | Generate_diffs -> run_generate root out
  | Check_idempotent -> run_check ()
