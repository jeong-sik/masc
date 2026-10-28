(* Per registration: the Server_auth wrappers (and their ~permission / ~tool_name
   argument text) the route runs.

   old files: Http.Router.<fn> path handler   -> wrappers found by following the
              handler into same-file definitions (depth 3)
   new files: Server_route.<fn> KIND path handler -> the wrapper KIND stands for,
              plus any wrapper still inside the handler

   A handler defined in another file is not followed, so a wrapper that lives
   there shows up on the old side as "no wrapper" (see the telemetry row in the
   README of this directory).

   usage: scan_args (old|new) FILE...
   output: one line per registration: file, fn, path text, wrappers (tab separated)

   build: ocamlfind ocamlopt -package compiler-libs.common -linkpkg scan_args.ml -o scan_args *)
open Parsetree

let wrapper_names =
  [ "with_public_read"; "with_read_auth"; "with_permission_auth"
  ; "with_token_permission_auth"; "with_private_token_permission_auth"
  ; "with_tool_auth"; "with_tool_actor_auth" ]

let registration_fns =
  [ "get"; "post"; "add"; "prefix_get"; "prefix_post"; "prefix_put"; "prefix_delete"; "ws_get" ]

let flatten lid = try Longident.flatten lid with _ -> []
let last l = match List.rev l with x :: _ -> x | [] -> ""

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

(* Every wrapper applied anywhere inside [e], following identifiers into
   same-file definitions. *)
let wrappers_in source defs (e : expression) =
  let found = ref [] in
  let rec visit depth (e : expression) =
    let it =
      { Ast_iterator.default_iterator with
        expr =
          (fun self (x : expression) ->
            (match x.pexp_desc with
             | Pexp_apply ({ pexp_desc = Pexp_ident { txt; _ }; _ }, args)
               when List.mem (last (flatten txt)) wrapper_names ->
               let name = last (flatten txt) in
               let arg label =
                 List.find_map
                   (function
                     | Asttypes.Labelled l, (a : expression) when l = label -> Some (slice source a.pexp_loc)
                     | _ -> None)
                   args
               in
               let text =
                 match name with
                 | "with_permission_auth" | "with_token_permission_auth"
                 | "with_private_token_permission_auth" ->
                   "permission=" ^ Option.value (arg "permission") ~default:"?"
                 | "with_tool_auth" | "with_tool_actor_auth" ->
                   "tool_name=" ^ Option.value (arg "tool_name") ~default:"?"
                 | _ -> ""
               in
               found := (name ^ "(" ^ text ^ ")") :: !found
             | Pexp_ident { txt = Longident.Lident n; _ } when depth < 3 ->
               List.iter (fun d -> visit (depth + 1) d) (Hashtbl.find_all defs n)
             | _ -> ());
            Ast_iterator.default_iterator.expr self x) }
    in
    it.expr it e
  in
  visit 0 e;
  List.sort_uniq compare !found

let kind_wrapper source (kind : expression) =
  let arg_text (a : expression) = slice source a.pexp_loc in
  match kind.pexp_desc with
  | Pexp_construct ({ txt; _ }, None) ->
    (match last (flatten txt) with
     | "Public_read" -> [ "with_public_read()" ]
     | "Read_auth" -> [ "with_read_auth()" ]
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
     | "Self_authenticated", _ -> []
     | _ -> [ "?kind:" ^ name ])
  | _ -> [ "?kind-not-a-constructor" ]

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
                       let own = match kind with Some k -> kind_wrapper source k | None -> [] in
                       let inner = wrappers_in source defs h in
                       let all = List.sort compare (own @ inner) in
                       let path_text = slice source p.pexp_loc in
                       let fn_name = if fn = "ws_get" then "ws_get" else fn in
                       Printf.printf "%s\t%s\t%s\t%s\n" base fn_name path_text (String.concat ";" all)
                     | _ -> Printf.printf "%s\t%s\t?\t?UNPARSED\n" base fn)
                  | _ -> ())
               | _ -> ());
              Ast_iterator.default_iterator.expr self e) }
      in
      it.structure it str)
    files
