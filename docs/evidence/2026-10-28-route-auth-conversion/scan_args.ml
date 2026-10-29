(* Per registration: every with_* helper the route runs, as the chain of helpers that
   enclose it (outermost first), with the ~permission / ~tool_name argument text of
   the seven Server_auth wrappers.

   A chain keeps the order the helpers run in: [with_a (fun ... -> with_b ...)] is
   "with_a>with_b", [with_b (fun ... -> with_a ...)] is "with_b>with_a". The chains of
   one registration are sorted but not deduplicated, so a helper that runs twice
   shows twice.

   old files: Http.Router.<fn> path handler   -> chains found by following the
              handler into same-file definitions (depth 3)
   new files: Server_route.<fn> KIND path handler -> the helpers KIND stands for
              (one for most kinds, two for Public_read_on_canonical_host) are the
              outermost links of every chain of the handler, and are chains themselves

   A handler defined in another file is not followed, so a helper that lives there
   shows up on the old side as "no helper" (see the telemetry row in the README of
   this directory).

   usage: scan_args (old|new) FILE...
   output: one line per registration: file, fn, path text, chains (tab separated;
           chains separated by ';')

   build: ocamlfind ocamlopt -package compiler-libs.common -linkpkg scan_args.ml -o scan_args *)
open Parsetree

let auth_wrappers =
  [ "with_public_read"; "with_read_auth"; "with_permission_auth"
  ; "with_token_permission_auth"; "with_private_token_permission_auth"
  ; "with_tool_auth"; "with_tool_actor_auth" ]

let registration_fns =
  [ "get"; "post"; "add"; "prefix_get"; "prefix_post"; "prefix_put"; "prefix_delete"; "ws_get" ]

let flatten lid = try Longident.flatten lid with _ -> []
let last l = match List.rev l with x :: _ -> x | [] -> ""

let is_with_helper name = String.length name > 5 && String.sub name 0 5 = "with_"

let normalize s =
  let b = Buffer.create (String.length s) in
  let space = ref false in
  String.iter
    (fun c ->
      if c = ' ' || c = '\n' || c = '\t' || c = '\r' then space := true
      else (
        if !space && Buffer.length b > 0 then Buffer.add_char b ' ';
        space := false;
        Buffer.add_char b c))
    s;
  Buffer.contents b

let slice source (loc : Location.t) =
  normalize
    (String.sub source loc.loc_start.pos_cnum (loc.loc_end.pos_cnum - loc.loc_start.pos_cnum))

let defs_of_structure str =
  let tbl = Hashtbl.create 64 in
  let it =
    { Ast_iterator.default_iterator with
      value_binding =
        (fun self vb ->
          (match vb.pvb_pat.ppat_desc with
           | Ppat_var { txt; _ } -> Hashtbl.add tbl txt vb.pvb_expr
           | _ -> ());
          Ast_iterator.default_iterator.value_binding self vb) }
  in
  it.structure it str;
  tbl

(* The text a chain link carries: the name, and for the seven auth wrappers the
   argument that decides who is let in. *)
let link_label source name args =
  let arg label =
    List.find_map
      (function
        | Asttypes.Labelled l, (a : expression) when l = label -> Some (slice source a.pexp_loc)
        | _ -> None)
      args
  in
  match name with
  | "with_permission_auth" | "with_token_permission_auth" | "with_private_token_permission_auth" ->
    name ^ "(permission=" ^ Option.value (arg "permission") ~default:"?" ^ ")"
  | "with_tool_auth" | "with_tool_actor_auth" ->
    name ^ "(tool_name=" ^ Option.value (arg "tool_name") ~default:"?" ^ ")"
  | _ -> name

(* Every application of a with_* helper inside [e], as the chain of with_* applications
   that enclose it, starting from [prefix]. Identifiers are followed into same-file
   definitions, up to three levels. *)
let chains_in source defs ~prefix (e : expression) =
  let found = ref [] in
  let rec visit depth stack (e : expression) =
    let it : Ast_iterator.iterator = iterator depth stack in
    it.Ast_iterator.expr it e
  and iterator depth stack : Ast_iterator.iterator =
    { Ast_iterator.default_iterator with
      expr =
        (fun self (x : expression) ->
          match x.pexp_desc with
          | Pexp_apply ({ pexp_desc = Pexp_ident { txt; _ }; _ }, args)
            when is_with_helper (last (flatten txt)) ->
            let chain = stack @ [ link_label source (last (flatten txt)) args ] in
            found := String.concat ">" chain :: !found;
            List.iter (fun (_, a) -> visit depth chain a) args
          | Pexp_ident { txt = Longident.Lident n; _ } when depth < 3 ->
            List.iter (fun d -> visit (depth + 1) stack d) (Hashtbl.find_all defs n)
          | _ -> Ast_iterator.default_iterator.expr self x) }
  in
  visit 0 prefix e;
  List.sort compare !found

(* The helpers the kind stands for, outermost first. *)
let kind_links source (kind : expression) =
  let arg_text (a : expression) = slice source a.pexp_loc in
  match kind.pexp_desc with
  | Pexp_construct ({ txt; _ }, None) ->
    (match last (flatten txt) with
     | "Public_read" -> [ "with_public_read" ]
     | "Read_auth" -> [ "with_read_auth" ]
     | "Always_public" | "Self_authenticated" -> []
     | other -> [ "?kind:" ^ other ])
  | Pexp_construct ({ txt; _ }, Some arg) ->
    let name = last (flatten txt) in
    (match name, arg.pexp_desc with
     | "Permission", _ -> [ "with_permission_auth(permission=" ^ arg_text arg ^ ")" ]
     | "Token_permission", _ -> [ "with_token_permission_auth(permission=" ^ arg_text arg ^ ")" ]
     | "Private_token_permission", _ ->
       [ "with_private_token_permission_auth(permission=" ^ arg_text arg ^ ")" ]
     | ("Tool" | "Tool_actor"), Pexp_record ([ (_, v) ], None) ->
       [ (if name = "Tool" then "with_tool_auth" else "with_tool_actor_auth")
         ^ "(tool_name=" ^ arg_text v ^ ")" ]
     | "Public_read_on_canonical_host", _ ->
       [ "with_canonical_loopback_host"; "with_public_read" ]
     | "Self_authenticated", _ -> []
     | _ -> [ "?kind:" ^ name ])
  | _ -> [ "?kind-not-a-constructor" ]

(* The chain of each prefix of [links]: the helpers a kind stands for enclose one
   another, so each one is a chain of its own and the next one is inside it. *)
let own_chains links =
  let rec go acc prefix = function
    | [] -> List.rev acc
    | link :: rest ->
      let chain = prefix @ [ link ] in
      go (String.concat ">" chain :: acc) chain rest
  in
  go [] [] links

let () =
  let mode = Sys.argv.(1) in
  let files = List.tl (List.tl (Array.to_list Sys.argv)) in
  List.iter
    (fun file ->
      let source = In_channel.with_open_bin file In_channel.input_all in
      let str = Pparse.parse_implementation ~tool_name:"scan_args" file in
      let defs = defs_of_structure str in
      let base = Filename.basename file in
      let it =
        { Ast_iterator.default_iterator with
          expr =
            (fun self (e : expression) ->
              (match e.pexp_desc with
               | Pexp_apply ({ pexp_desc = Pexp_ident { txt; _ }; _ }, args) ->
                 (match List.rev (flatten txt) with
                  | fn :: m :: _
                    when List.mem fn registration_fns
                         && ((mode = "old" && m = "Router") || (mode = "new" && m = "Server_route")) ->
                    let positional =
                      List.filter_map (function Asttypes.Nolabel, a -> Some a | _ -> None) args
                    in
                    let labelled l =
                      List.find_map
                        (function Asttypes.Labelled x, a when x = l -> Some a | _ -> None)
                        args
                    in
                    let kind, path, handler =
                      match mode, fn, positional with
                      | _, "ws_get", p :: h :: _ -> None, Some p, Some h
                      | "old", "add", _ -> None, labelled "path", labelled "handler"
                      | "old", _, [ p; h ] -> None, Some p, Some h
                      | "new", "add", [ k; h ] -> Some k, labelled "path", Some h
                      | "new", _, [ k; p; h ] -> Some k, Some p, Some h
                      | _ -> None, None, None
                    in
                    (match path, handler with
                     | Some p, Some h ->
                       let links = Option.fold ~none:[] ~some:(kind_links source) kind in
                       let inner = chains_in source defs ~prefix:links h in
                       let all = List.sort compare (own_chains links @ inner) in
                       Printf.printf "%s\t%s\t%s\t%s\n" base fn (slice source p.pexp_loc)
                         (String.concat ";" all)
                     | _ -> Printf.printf "%s\t%s\t?\t?UNPARSED\n" base fn)
                  | _ -> ())
               | _ -> ());
              Ast_iterator.default_iterator.expr self e) }
      in
      it.structure it str)
    files
