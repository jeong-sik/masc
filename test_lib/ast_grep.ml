(* RFC-0085 PR-1 — AST-based structural verification for regression
   tests.  Skips comments and docstrings (which trapped RFC-0084
   PR-E / PR-F / PR-A / PR-I-3 source-grep regressions). *)

let parse_implementation path =
  let ic = open_in path in
  let lexbuf = Lexing.from_channel ic in
  Lexing.set_filename lexbuf path;
  let result =
    try Ok (Parse.implementation lexbuf) with
    | Syntaxerr.Error _ as e ->
      close_in ic;
      Error (Printexc.to_string e)
  in
  close_in ic;
  result
;;

(* Flatten Longident.t into "M.N.field" / "name". *)
let rec longident_to_string : Longident.t -> string = function
  | Lident s -> s
  | Ldot (rest, name) ->
    longident_to_string rest.Location.txt ^ "." ^ name.Location.txt
  | Lapply (l, r) ->
    longident_to_string l.Location.txt
    ^ "("
    ^ longident_to_string r.Location.txt
    ^ ")"
;;

(* Count function-application sites where the callee identifier matches
   [callee] exactly (string form "Module.fn" or just "fn" for unqualified).
   Skips comments / docstrings (AST has no nodes for them). *)
let count_calls ~module_path ~callee =
  match parse_implementation module_path with
  | Error _ -> 0
  | Ok structure ->
    let count = ref 0 in
    let iter =
      { Ast_iterator.default_iterator with
        expr =
          (fun self e ->
            (match e.pexp_desc with
             | Pexp_apply ({ pexp_desc = Pexp_ident { txt; _ }; _ }, _) ->
               if longident_to_string txt = callee then incr count
             | _ -> ());
            Ast_iterator.default_iterator.expr self e)
      }
    in
    iter.structure iter structure;
    !count
;;

(* Count string literals whose value contains [needle] as a substring.
   Excludes comments and docstrings — those are not Pconst_string
   nodes in the Parsetree. *)
let count_string_literals ~module_path ~needle =
  match parse_implementation module_path with
  | Error _ -> 0
  | Ok structure ->
    let count = ref 0 in
    let needle_len = String.length needle in
    let contains haystack =
      if needle_len = 0
      then false
      else (
        let h_len = String.length haystack in
        let rec scan i =
          if i + needle_len > h_len
          then false
          else if String.sub haystack i needle_len = needle
          then true
          else scan (i + 1)
        in
        scan 0)
    in
    let iter =
      { Ast_iterator.default_iterator with
        expr =
          (fun self e ->
            (match e.pexp_desc with
             | Pexp_constant { pconst_desc = Pconst_string (s, _, _); _ } ->
               if contains s then incr count
             | _ -> ());
            Ast_iterator.default_iterator.expr self e)
      }
    in
    iter.structure iter structure;
    !count
;;
