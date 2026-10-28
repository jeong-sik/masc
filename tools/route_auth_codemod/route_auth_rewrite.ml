open Parsetree

type site =
  { line : int
  ; path : string
  ; note : string
  }

type report =
  { converted : int
  ; definitions : int
  ; named : site list
  ; unhandled : site list
  ; early : site list
  }

type edit =
  { start : int
  ; stop : int
  ; text : string
  }

(* Edits are made on the original text, so none may overlap. Edits that start at
   the same offset keep the order they were given in. *)
let apply_edits source edits =
  let sorted = List.stable_sort (fun a b -> compare a.start b.start) edits in
  let buffer = Buffer.create (String.length source) in
  let position =
    List.fold_left
      (fun position edit ->
        if edit.start < position
        then failwith "two edits overlap"
        else (
          Buffer.add_string buffer (String.sub source position (edit.start - position));
          Buffer.add_string buffer edit.text;
          edit.stop))
      0
      sorted
  in
  Buffer.add_string buffer (String.sub source position (String.length source - position));
  Buffer.contents buffer
;;

(* The wrappers of Server_auth that a typed registration replaces. Each entry has
   the label that carries the wrapper's argument, if any, and the text of the
   Server_route kind that stands for it, given that argument's source. *)
let kinds =
  [ "with_public_read", (None, fun _ -> "Server_route.Public_read")
  ; "with_read_auth", (None, fun _ -> "Server_route.Read_auth")
  ; ( "with_permission_auth"
    , (Some "permission", Printf.sprintf "(Server_route.Permission %s)") )
  ; ( "with_token_permission_auth"
    , (Some "permission", Printf.sprintf "(Server_route.Token_permission %s)") )
  ; ( "with_private_token_permission_auth"
    , (Some "permission", Printf.sprintf "(Server_route.Private_token_permission %s)") )
  ; ( "with_tool_auth"
    , (Some "tool_name", Printf.sprintf "(Server_route.Tool { tool_name = %s })") )
  ; ( "with_tool_actor_auth"
    , (Some "tool_name", Printf.sprintf "(Server_route.Tool_actor { tool_name = %s })") )
  ]
;;

(* Registration functions of Http_server_eio.Router that Server_route has a typed
   counterpart for. [ws_get] is left out: Server_route.ws_get takes no kind. *)
let registration_names =
  [ "get"; "post"; "add"; "prefix_get"; "prefix_post"; "prefix_put"; "prefix_delete" ]
;;

let non_literal_path = "<non-literal>"
let flatten lid = try Longident.flatten lid with Misc.Fatal_error -> []

let last_component lid =
  match List.rev (flatten lid) with
  | name :: _ -> name
  | [] -> ""
;;

(* [Some name] for [Router.name] under any qualification. *)
let registration_function (e : expression) =
  match e.pexp_desc with
  | Pexp_ident { txt; _ } ->
    (match List.rev (flatten txt) with
     | name :: "Router" :: _ when List.mem name registration_names -> Some name
     | _ -> None)
  | _ -> None
;;

let slice source (loc : Location.t) =
  String.sub
    source
    loc.loc_start.pos_cnum
    (loc.loc_end.pos_cnum - loc.loc_start.pos_cnum)
;;

let has_attributes (e : expression) =
  match e.pexp_attributes with
  | [] -> false
  | _ :: _ -> true
;;

(* ---- lines and comments ---- *)

let is_blank = function
  | ' ' | '\t' | '\n' | '\r' -> true
  | _ -> false
;;

let rec skip_blank_back source i =
  if i > 0 && is_blank source.[i - 1] then skip_blank_back source (i - 1) else i
;;

let line_start source offset =
  let rec back i = if i > 0 && source.[i - 1] <> '\n' then back (i - 1) else i in
  back offset
;;

(* The spaces and tabs a line starts with. *)
let leading_blanks source line =
  let rec forward i =
    if i < String.length source && (source.[i] = ' ' || source.[i] = '\t')
    then forward (i + 1)
    else i
  in
  String.sub source line (forward line - line)
;;

let leading_spaces line =
  let rec count i = if i < String.length line && line.[i] = ' ' then count (i + 1) else i in
  count 0
;;

(* Moves a comment that starts in [from_column] so that it starts in
   [to_column]. Its later lines move by the same amount, so they stay under the
   text they were aligned with. *)
let reindent text ~from_column ~to_column =
  match String.split_on_char '\n' text with
  | [] -> text
  | first :: rest ->
    let shift line =
      let removed = min (leading_spaces line) (max 0 (from_column - to_column)) in
      String.make (max 0 (to_column - from_column)) ' '
      ^ String.sub line removed (String.length line - removed)
    in
    String.concat "\n" (first :: List.map shift rest)
;;

(* The comments of source[start, stop), verbatim, each with the offset it starts
   at. [None] when the range holds a doc comment, or does not lex. *)
let comments_between source ~start ~stop =
  let text = String.sub source start (stop - start) in
  let lexbuf = Lexing.from_string text in
  Lexer.init ();
  let rec collect found =
    match Lexer.token_with_comments lexbuf with
    | Parser.EOF -> Some (List.rev found)
    | Parser.COMMENT (_, loc) ->
      let first = loc.loc_start.pos_cnum in
      let last = loc.loc_end.pos_cnum in
      collect ((start + first, String.sub text first (last - first)) :: found)
    | Parser.DOCSTRING _ -> None
    | _ -> collect found
  in
  try collect [] with
  | Lexer.Error _ -> None
;;

(* Replacing the registration function discards its exact source range. *)
let registration_function_issue source (fn : expression) =
  if has_attributes fn then Some "registration function has an attribute"
  else
    match comments_between source ~start:fn.pexp_loc.loc_start.pos_cnum
            ~stop:fn.pexp_loc.loc_end.pos_cnum with
    | Some [] -> None
    | Some (_ :: _) -> Some "registration function contains a comment"
    | None -> Some "registration function contains unreadable text or a doc comment"
;;

(* A comment as a line of its own, indented like the registration it moves to. *)
let hoisted source ~indent (offset, text) =
  let from_column = offset - line_start source offset in
  indent ^ reindent text ~from_column ~to_column:(String.length indent) ^ "\n"
;;

(* ---- the wrapper call ---- *)

type call =
  { wrapper : string
  ; labeled : (string * expression) list
  ; positional : expression list
  ; optional : int  (** Arguments given as [?label]. *)
  }

let wrapper_call (e : expression) =
  match e.pexp_desc with
  | Pexp_apply (({ pexp_desc = Pexp_ident { txt; _ }; _ } as fn), args)
    when not (has_attributes fn) && List.mem_assoc (last_component txt) kinds ->
    let labeled =
      List.filter_map
        (function
          | Asttypes.Labelled label, arg -> Some (label, arg)
          | _ -> None)
        args
    in
    let positional =
      List.filter_map
        (function
          | Asttypes.Nolabel, arg -> Some arg
          | _ -> None)
        args
    in
    Some
      { wrapper = last_component txt
      ; labeled
      ; positional
      ; optional = List.length args - List.length labeled - List.length positional
      }
  | _ -> None
;;

let mentions (e : expression) name =
  let found = ref false in
  let iterator =
    { Ast_iterator.default_iterator with
      expr =
        (fun self (e : expression) ->
          (match e.pexp_desc with
           | Pexp_ident { txt = Longident.Lident n; _ } when String.equal n name ->
             found := true
           | _ -> ());
          Ast_iterator.default_iterator.expr self e)
    }
  in
  iterator.expr iterator e;
  !found
;;

(* A value that is the same whenever it is evaluated. *)
let rec is_constant (e : expression) =
  if has_attributes e then false
  else match e.pexp_desc with
    | Pexp_constant _ | Pexp_ident _ | Pexp_construct (_, None) -> true
    | Pexp_construct (_, Some argument) -> is_constant argument
    | _ -> false
;;

(* The handler a wrapper wraps. A call such as [make_handler config] inside the
   function of the registration runs on every request, and after the rewrite it
   would run once at registration. *)
let is_function_or_name (e : expression) =
  match e.pexp_desc with
  | Pexp_function _ | Pexp_ident _ -> true
  | _ -> false
;;

(* The text of the [Server_route.auth] value that goes with the wrapper, and the
   argument that is now evaluated once at registration where it was evaluated on
   every request. [outer_params] is [Some] when the wrapper sits inside the
   function of the registration; a wrapper applied directly was evaluated once
   already. *)
let kind_text source call ~outer_params ~allow_early =
  match List.assoc_opt call.wrapper kinds with
  | None -> Error ("no kind for " ^ call.wrapper)
  | Some (label, build) ->
    if List.map fst call.labeled <> Option.to_list label
    then
      Error
        (Printf.sprintf "%s is called with labels the tool does not know" call.wrapper)
    else (
      match label with
      | None -> Ok (build "", None)
      | Some name ->
        let value = List.assoc name call.labeled in
        let text = slice source value.pexp_loc in
        (match outer_params with
         | None -> Ok (build text, None)
         | Some outer_params ->
           if List.exists (mentions value) outer_params
           then
             Error
               (Printf.sprintf
                  "~%s of %s reads the request of the outer function"
                  name
                  call.wrapper)
           else if is_constant value
           then Ok (build text, None)
           else if allow_early
           then Ok (build text, Some text)
           else
             Error
               (Printf.sprintf
                  "~%s of %s is computed, so it would be evaluated at registration \
                   instead of on every request"
                  name
                  call.wrapper)))
;;

(* ---- the handler ---- *)

type shape =
  | Applied of
      { call : call
      ; inner : expression
      ; outer_params : string list
      }  (** [fun request reqd -> W ... h request reqd] *)
  | Partial of
      { call : call
      ; inner : expression
      }  (** [W ... h] *)
  | Other of string

let simple_params params =
  let name = function
    | { pparam_desc =
          Pparam_val
            (Asttypes.Nolabel, None, { ppat_desc = Ppat_var { txt; _ }; ppat_attributes = []; _ })
      ; _
      } -> Some txt
    | _ -> None
  in
  let names = List.map name params in
  if List.for_all Option.is_some names then Some (List.filter_map Fun.id names) else None
;;

let has_parameter_attributes params =
  List.exists
    (fun param ->
      match param.pparam_desc with
      | Pparam_val (_, _, pattern) -> pattern.ppat_attributes <> []
      | Pparam_newtype _ -> false)
    params
;;

let ident_name (e : expression) =
  match e.pexp_desc with
  | Pexp_ident { txt = Longident.Lident name; _ } when not (has_attributes e) -> Some name
  | _ -> None
;;

let describe_handler source (handler : expression) =
  match handler.pexp_desc with
  | Pexp_ident _ -> "named handler " ^ slice source handler.pexp_loc
  | Pexp_apply ({ pexp_desc = Pexp_ident { txt; _ }; _ }, _) ->
    "handler is a call of " ^ String.concat "." (flatten txt)
  | _ -> "handler is not a wrapper call"
;;

let classify source (handler : expression) =
  if has_attributes handler
  then Other "the handler has an attribute"
  else (
    match handler.pexp_desc with
    | Pexp_function (params, None, Pfunction_body body) ->
      if has_parameter_attributes params
      then Other "the outer handler parameter has an attribute"
      else (match simple_params params, wrapper_call body with
       | Some [ request; reqd ], Some call ->
         if call.optional > 0 || has_attributes body
         then Other "the wrapper call has optional arguments or attributes"
         else (
           match call.positional with
           | [ inner; a; b ]
             when ident_name a = Some request && ident_name b = Some reqd ->
             Applied { call; inner; outer_params = [ request; reqd ] }
           | _ -> Other "the wrapper is not applied to the request and reqd of the handler")
       | Some [ _; _ ], None -> Other "handler body is not a wrapper call"
       | _ -> Other "handler does not take exactly request and reqd")
    | Pexp_apply _ ->
      (match wrapper_call handler with
       | Some ({ positional = [ inner ]; optional = 0; _ } as call) ->
         Partial { call; inner }
       | Some _ -> Other "the wrapper is partially applied with other arguments"
       | None -> Other (describe_handler source handler))
    | _ -> Other (describe_handler source handler))
;;

(* ---- names the inner handler uses ---- *)

(* Every name a pattern binds anywhere inside [e], parameters included. *)
let binders_in (e : expression) =
  let names = ref [] in
  let iterator =
    { Ast_iterator.default_iterator with
      pat =
        (fun self (p : pattern) ->
          (match p.ppat_desc with
           | Ppat_var { txt; _ } | Ppat_alias (_, { txt; _ }) -> names := txt :: !names
           | _ -> ());
          Ast_iterator.default_iterator.pat self p)
    }
  in
  iterator.expr iterator e;
  !names
;;

let pattern_vars (p : pattern) =
  let names = ref [] in
  let iterator =
    { Ast_iterator.default_iterator with
      pat =
        (fun self (p : pattern) ->
          (match p.ppat_desc with
           | Ppat_var { txt; _ } | Ppat_alias (_, { txt; _ }) -> names := txt :: !names
           | _ -> ());
          Ast_iterator.default_iterator.pat self p)
    }
  in
  iterator.pat iterator p;
  !names
;;

(* The names [inner] binds as the parameters of its own function. *)
let own_params (inner : expression) =
  match inner.pexp_desc with
  | Pexp_function (params, _, _) ->
    List.concat_map
      (function
        | { pparam_desc = Pparam_val (_, _, pattern); _ } -> pattern_vars pattern
        | _ -> [])
      params
  | _ -> []
;;

type outer_read =
  | Not_read  (** The inner handler never reads the name, or binds it as its own parameter. *)
  | Free  (** It reads the name and nothing inside it binds the name, so it is the outer one. *)
  | Ambiguous  (** It reads the name and also binds it deeper down. *)

let outer_read inner name =
  if List.mem name (own_params inner) || not (mentions inner name)
  then Not_read
  else if List.mem name (binders_in inner)
  then Ambiguous
  else Free
;;

(* The last [count] elements of [items], or [None] when there are fewer. *)
let last_elements items count =
  let skip = List.length items - count in
  if skip < 0 then None else Some (List.filteri (fun index _ -> index >= skip) items)
;;

(* How a parameter of the inner handler gets the name of an outer parameter. *)
type binding =
  | Rename of pattern * string  (** The parameter is unused and takes the outer name. *)
  | Alias of string * string  (** [let outer = parameter in] opens the body. *)

let binding_for inner name (param : function_param) =
  match param.pparam_desc with
  | Pparam_val (Asttypes.Nolabel, None, pattern) ->
    if pattern.ppat_attributes <> []
    then Error "the wrapped handler parameter has an attribute"
    else (match pattern.ppat_desc with
     | Ppat_any -> Ok (Rename (pattern, name))
     | Ppat_var { txt; _ } when mentions inner txt -> Ok (Alias (name, txt))
     | Ppat_var _ -> Ok (Rename (pattern, name))
     | _ ->
       Error
         (Printf.sprintf
            "the parameter that stands for the outer %s is a pattern the tool does not rename"
            name))
  | _ ->
    Error
      (Printf.sprintf "the parameter that stands for the outer %s is not a plain parameter" name)
;;

(* The inner handler may read the request or reqd of the outer function instead
   of its own parameters. Those names are free once the outer function is gone.
   Every wrapper hands its own request and reqd on to the handler, so the last two
   parameters of the inner handler hold the same values as the outer ones. The
   parameter in the same position takes the outer name when it is unused, and the
   body starts by naming it when it is used. Returns the text of the inner
   handler. *)
let bind_outer_names source (inner : expression) outer_params =
  let ( let* ) = Result.bind in
  let reads = List.map (fun name -> name, outer_read inner name) outer_params in
  match List.find_opt (fun (_, read) -> read = Ambiguous) reads with
  | Some (name, _) ->
    Error
      (Printf.sprintf "the wrapped handler binds %s itself and may read the outer one" name)
  | None ->
    if not (List.exists (fun (_, read) -> read = Free) reads)
    then Ok (slice source inner.pexp_loc)
    else (
      match inner.pexp_desc with
      | Pexp_function (params, _, body) ->
        (match last_elements params (List.length outer_params) with
         | None -> Error "the wrapped handler has fewer parameters than the outer function"
         | Some own ->
           let rec plan reads own =
             match reads, own with
             | (name, Free) :: reads, param :: own ->
               let* binding = binding_for inner name param in
               let* later = plan reads own in
               Ok (binding :: later)
             | (_, (Not_read | Ambiguous)) :: reads, _ :: own -> plan reads own
             | _ -> Ok []
           in
           let* bindings = plan reads own in
           let base = inner.pexp_loc.loc_start.pos_cnum in
           let renames =
             List.filter_map
               (function
                 | Rename (pattern, name) ->
                   Some
                     { start = pattern.ppat_loc.loc_start.pos_cnum - base
                     ; stop = pattern.ppat_loc.loc_end.pos_cnum - base
                     ; text = name
                     }
                 | Alias _ -> None)
               bindings
           in
           let aliases =
             List.filter_map
               (function
                 | Alias (name, parameter) -> Some (Printf.sprintf "let %s = %s in " name parameter)
                 | Rename _ -> None)
               bindings
           in
           let* alias_edits =
             match aliases, body with
             | [], _ -> Ok []
             | _, Pfunction_body body ->
               let at = body.pexp_loc.loc_start.pos_cnum - base in
               Ok [ { start = at; stop = at; text = String.concat "" aliases } ]
             | _, Pfunction_cases _ ->
               Error "the wrapped handler is a function over cases, so its body cannot start with a let"
           in
           Ok (apply_edits (slice source inner.pexp_loc) (renames @ alias_edits)))
      | _ -> Error "the wrapped handler is not a function but reads the outer names")
;;

(* ---- one registration ---- *)

let route_path (args : (Asttypes.arg_label * expression) list) =
  let literal (e : expression) =
    match e.pexp_desc with
    | Pexp_constant { pconst_desc = Pconst_string (text, _, _); _ } -> Some text
    | _ -> None
  in
  List.find_map (fun (_, arg) -> literal arg) args
  |> Option.value ~default:non_literal_path
;;

let handler_label = "~handler:"

(* The handler argument of a registration. *)
let handler_expression name (args : (Asttypes.arg_label * expression) list) =
  if String.equal name "add"
  then
    List.find_map
      (function
        | Asttypes.Labelled "handler", handler -> Some handler
        | _ -> None)
      args
  else (
    match List.filter_map (function Asttypes.Nolabel, a -> Some a | _ -> None) args with
    | _ :: handler :: _ -> Some handler
    | _ -> None)
;;

(* The handler argument and the offset where its edit starts. [Router.add] takes
   the handler as [~handler:h]; the edit then starts at the label, because
   [Server_route.add] takes it positionally. *)
let handler_arg source name args =
  match handler_expression name args with
  | None -> Error (if String.equal name "add" then "no ~handler argument" else "no handler argument")
  | Some handler when not (String.equal name "add") ->
    Ok (handler, handler.pexp_loc.loc_start.pos_cnum)
  | Some handler ->
    let label_end = skip_blank_back source handler.pexp_loc.loc_start.pos_cnum in
    let label_start = label_end - String.length handler_label in
    if label_start >= 0
       && String.equal
            (String.sub source label_start (String.length handler_label))
            handler_label
    then Ok (handler, label_start)
    else Error "cannot find the ~handler: label in the source"
;;

(* What a wrapped handler becomes: the kind that stands for its wrapper, the text
   of the handler inside the wrapper, the argument that is now evaluated once at
   registration, and the comments that were inside the text that goes away. *)
type unwrapped =
  { kind : string
  ; inner : expression
  ; inner_text : string
  ; evaluated_once : string option
  ; hoisted : (int * string) list
  ; scope_arguments : expression list
  ; partial : bool
  }

(* [handler] is a wrapped handler. The text from [before] to [after] goes away
   except the handler inside the wrapper. *)
let unwrap ~allow_early source (handler : expression) ~before ~after =
  let ( let* ) = Result.bind in
  let* call, inner, inner_text, outer_params =
    match classify source handler with
    | Other reason -> Error reason
    | Applied { call; inner; outer_params } ->
      let* () =
        if is_function_or_name inner
        then Ok ()
        else Error "the wrapped handler is a call, which would run at registration"
      in
      let* inner_text = bind_outer_names source inner outer_params in
      Ok (call, inner, inner_text, Some outer_params)
    | Partial { call; inner } -> Ok (call, inner, slice source inner.pexp_loc, None)
  in
  let* kind, evaluated_once = kind_text source call ~outer_params ~allow_early in
  let inner_start = inner.pexp_loc.loc_start.pos_cnum in
  let inner_stop = inner.pexp_loc.loc_end.pos_cnum in
  (* The wrapper and its closing parenthesis are dropped. The comments inside
     them move above the line of the registration. *)
  let unreadable = "the wrapper holds a doc comment, or text the tool cannot read" in
  let* comments_before =
    Option.to_result
      ~none:unreadable
      (comments_between source ~start:before ~stop:inner_start)
  in
  let* comments_after =
    Option.to_result
      ~none:unreadable
      (comments_between source ~start:inner_stop ~stop:after)
  in
  (* A comment inside an argument that is copied into the kind goes along with
     it; moving it as well would write it twice. *)
  let copied (offset, _) =
    List.exists
      (fun (_, (value : expression)) ->
        value.pexp_loc.loc_start.pos_cnum <= offset
        && offset < value.pexp_loc.loc_end.pos_cnum)
      call.labeled
  in
  Ok
    { kind
    ; inner
    ; inner_text
    ; evaluated_once
    ; hoisted = List.filter (fun comment -> not (copied comment)) (comments_before @ comments_after)
    ; scope_arguments = List.map snd call.labeled
    ; partial = Option.is_none outer_params
    }
;;

(* The comments as lines of their own above the line that holds [anchor]. *)
let comment_edits source ~anchor comments =
  match comments with
  | [] -> []
  | _ :: _ ->
    let line = line_start source anchor in
    let indent = leading_blanks source line in
    [ { start = line
      ; stop = line
      ; text = String.concat "" (List.map (hoisted source ~indent) comments)
      }
    ]
;;

type conversion =
  { edits : edit list
  ; evaluated_once : string option
      (** The wrapper argument that was evaluated on every request and is now
          evaluated at registration. *)
  }

(* The kind is inserted as a separate registration argument. If it contains a
   computation, moving it from the partial wrapper application can reorder it
   relative to the other arguments and handler creation. Keep the supported
   effectful expression only when those other expressions are syntactic values. *)
let has_attribute_or_extension (e : expression) =
  let found = ref false in
  let iterator =
    { Ast_iterator.default_iterator with
      attribute = (fun _ _ -> found := true)
    ; extension = (fun _ _ -> found := true)
    }
  in
  iterator.expr iterator e;
  !found
;;

let rec syntactic_value (e : expression) =
  if has_attributes e then false
  else
    match e.pexp_desc with
    | Pexp_constant _ -> true
    | Pexp_function _ -> not (has_attribute_or_extension e)
    | Pexp_ident { txt; _ } -> flatten txt <> []
    | Pexp_construct (_, argument) -> Option.fold ~none:true ~some:syntactic_value argument
    | Pexp_variant (_, argument) -> Option.fold ~none:true ~some:syntactic_value argument
    | Pexp_tuple elements -> List.for_all (fun (_, e) -> syntactic_value e) elements
    | _ -> false
;;

let rewrite_registration ~allow_early source (fn : expression) name args =
  let ( let* ) = Result.bind in
  let* handler, handler_start = handler_arg source name args in
  let* unwrapped =
    unwrap
      ~allow_early
      source
      handler
      ~before:handler_start
      ~after:handler.pexp_loc.loc_end.pos_cnum
  in
  let* () =
    if unwrapped.partial
       && List.exists (fun argument -> not (is_constant argument)) unwrapped.scope_arguments
       && (not (syntactic_value unwrapped.inner)
           || List.exists (fun (_, arg) -> arg != handler && not (syntactic_value arg)) args)
    then Error "a computed partial wrapper argument may be reordered with other registration effects"
    else Ok ()
  in
  let fn_start = fn.pexp_loc.loc_start.pos_cnum in
  Ok
    { edits =
        comment_edits source ~anchor:fn_start unwrapped.hoisted
        @ [ { start = fn_start
            ; stop = fn.pexp_loc.loc_end.pos_cnum
            ; text = Printf.sprintf "Server_route.%s %s" name unwrapped.kind
            }
          ; { start = handler_start
            ; stop = handler.pexp_loc.loc_end.pos_cnum
            ; text = unwrapped.inner_text
            }
          ]
    ; evaluated_once = unwrapped.evaluated_once
    }
;;

(* ---- named handlers ---- *)

(* A top-level [let name request reqd = wrapper ... request reqd], or
   [let name = wrapper ...]. The wrapper moves to the registrations that use the
   name, which takes it as the kind. *)
type definition =
  { name : string
  ; line : int
  ; scope : structure
  ; unwrapped : unwrapped
  ; binding_start : int
  ; name_stop : int
  ; binding_stop : int
  }

let definition ~allow_early ~scope source (item : structure_item) =
  match item.pstr_desc with
  | Pstr_value
      ( Asttypes.Nonrecursive
      , [ { pvb_pat = { ppat_desc = Ppat_var { txt = name; _ }; ppat_loc; _ }
          ; pvb_expr
          ; pvb_constraint = None
          ; pvb_attributes = []
          ; pvb_loc
          ; _
          }
        ] ) ->
    let name_stop = ppat_loc.loc_end.pos_cnum in
    let binding_stop = pvb_loc.loc_end.pos_cnum in
    (match
       unwrap ~allow_early source pvb_expr ~before:name_stop ~after:binding_stop
     with
     | Error _ -> None
     | Ok unwrapped ->
       Some
         { name
         ; line = ppat_loc.loc_start.pos_lnum
         ; scope
         ; unwrapped
         ; binding_start = pvb_loc.loc_start.pos_cnum
         ; name_stop
         ; binding_stop
         })
  | _ -> None
;;

let handler_ident (e : expression) =
  match e.pexp_desc with
  | Pexp_ident { txt = Longident.Lident name; _ } -> Some name
  | _ -> None
;;

(* How many registrations take the bare name [name] as their handler, and how
   many times the name appears at all. A definition may lose its wrapper only
   when the two are equal. *)
let uses_of_name source structure (definition : definition) =
  let name = definition.name in
  let registrations = ref 0 in
  let occurrences = ref 0 in
  let bindings = ref 0 in
  let earliest_registration = ref max_int in
  let latest_registration = ref min_int in
  let unsafe_registration = ref None in
  let scopes = ref [] in
  let outside_scope = ref false in
  let iterator =
    { Ast_iterator.default_iterator with
      structure =
        (fun self items ->
          scopes := items :: !scopes;
          Fun.protect ~finally:(fun () -> scopes := List.tl !scopes) (fun () ->
            Ast_iterator.default_iterator.structure self items))
    ; pat =
        (fun self (p : pattern) ->
          (match p.ppat_desc with
           | Ppat_var { txt; _ } | Ppat_alias (_, { txt; _ }) when String.equal txt name ->
             incr bindings
           | _ -> ());
          Ast_iterator.default_iterator.pat self p)
    ; structure_item =
        (fun self (item : structure_item) ->
          (match item.pstr_desc with
           | Pstr_primitive value when String.equal value.pval_name.txt name -> incr bindings
           | _ -> ());
          Ast_iterator.default_iterator.structure_item self item)
    ;
      expr =
        (fun self (e : expression) ->
          (match e.pexp_desc with
           (* A qualified use [M.h] in the same file can still refer to this
              binding, even though registrations are required to use bare [h].
              Count any matching final component conservatively: source-only
              analysis cannot prove which module a qualified name resolves to. *)
           | Pexp_ident { txt = (Longident.Lident n | Longident.Ldot (_, { txt = n; _ })); _ }
             when String.equal n name ->
             incr occurrences
           | Pexp_apply (fn, args) ->
             Option.iter
               (fun function_name ->
                 match Option.bind (handler_expression function_name args) handler_ident with
                 | Some n when String.equal n name ->
                   incr registrations;
                   (match registration_function_issue source fn with
                    | Some reason -> unsafe_registration := Some reason
                    | None -> ());
                   if not (List.exists (fun scope -> scope == definition.scope) !scopes)
                   then outside_scope := true;
                   earliest_registration := min !earliest_registration e.pexp_loc.loc_start.pos_cnum;
                   latest_registration := max !latest_registration e.pexp_loc.loc_end.pos_cnum
                 | _ -> ())
               (registration_function fn)
           | _ -> ());
          Ast_iterator.default_iterator.expr self e)
    }
  in
  iterator.structure iterator structure;
  ( !registrations
  , !occurrences
  , !bindings
  , !earliest_registration
  , !latest_registration
  , !outside_scope
  , !unsafe_registration )
;;

(* Moving a wrapper argument from a named definition to a registration also
   moves its lexical scope. Prove the names in the supported expression remain
   unobscured; unknown expression forms and scope-opening constructs are left
   for a manual conversion. This intentionally over-approximates later scopes. *)
let scope_safe_arguments structure (definition : definition) ~last_registration =
  let names = ref [] in
  let add_name lid =
    match flatten lid with
    | first :: _ -> names := first :: !names; true
    | [] -> false
  in
  let rec supported (e : expression) =
    match e.pexp_attributes, e.pexp_desc with
    | _ :: _, _ -> false
    | [], Pexp_constant _ -> true
    | [], Pexp_ident { txt; _ } -> add_name txt
    | [], Pexp_construct ({ txt; _ }, argument) ->
      add_name txt && Option.fold ~none:true ~some:supported argument
    | [], Pexp_apply (fn, args) -> supported fn && List.for_all (fun (_, arg) -> supported arg) args
    | [], _ -> false
  in
  if not (List.for_all supported definition.unwrapped.scope_arguments)
  then false
  else (
    let changed = ref false in
    let after loc =
      let position = loc.Location.loc_start.pos_cnum in
      position >= definition.binding_stop && position <= last_registration in
    let named name loc = if after loc && List.mem name !names then changed := true in
    let contains_registration body =
      let found = ref false in
      let iterator =
        { Ast_iterator.default_iterator with
          expr = (fun self (e : expression) ->
            (match e.pexp_desc with
             | Pexp_apply (fn, args) ->
               Option.iter (fun function_name ->
                 match Option.bind (handler_expression function_name args) handler_ident with
                 | Some name when String.equal name definition.name -> found := true
                 | Some _ | None -> ()) (registration_function fn)
             | _ -> ());
            Ast_iterator.default_iterator.expr self e)
        }
      in
      iterator.expr iterator body;
      !found
    in
    let iterator =
      { Ast_iterator.default_iterator with
        pat =
          (fun self (p : pattern) ->
            (match p.ppat_desc with
             | Ppat_var { txt; loc } | Ppat_alias (_, { txt; loc }) -> named txt loc
             | Ppat_unpack ({ txt; loc }, _) -> Option.iter (fun name -> named name loc) txt
             | Ppat_extension _ when after p.ppat_loc -> changed := true
             | _ -> ());
            Ast_iterator.default_iterator.pat self p)
      ; module_binding =
          (fun self binding ->
            Option.iter (fun name -> named name binding.pmb_name.loc) binding.pmb_name.txt;
            Ast_iterator.default_iterator.module_binding self binding)
      ; constructor_declaration =
          (fun self constructor ->
            named constructor.pcd_name.txt constructor.pcd_name.loc;
            Ast_iterator.default_iterator.constructor_declaration self constructor)
      ; extension_constructor =
          (fun self constructor ->
            named constructor.pext_name.txt constructor.pext_name.loc;
            Ast_iterator.default_iterator.extension_constructor self constructor)
      ; module_expr =
          (fun self (module_expr : module_expr) ->
            (match module_expr.pmod_desc with
             | Pmod_functor (Named (name, _), _) -> Option.iter (fun n -> named n name.loc) name.txt
             | _ -> ());
            Ast_iterator.default_iterator.module_expr self module_expr)
      ; structure_item =
          (fun self (item : structure_item) ->
            (match item.pstr_desc with
             | Pstr_open _ | Pstr_include _ | Pstr_extension _ when after item.pstr_loc -> changed := true
             | Pstr_primitive value -> named value.pval_name.txt value.pval_name.loc
             | _ -> ());
            Ast_iterator.default_iterator.structure_item self item)
      ; expr =
          (fun self (e : expression) ->
            (match e.pexp_desc with
             | Pexp_extension _ when after e.pexp_loc -> changed := true
             (* [M.(...)] has a synthetic [Pstr_open] with pos_cnum = -1.
                Its scope is only the body: use the enclosing expression's
                location and check whether that body contains a registration
                of this handler, rather than rejecting unrelated local opens. *)
             | Pexp_struct_item ({ pstr_desc = Pstr_open _; pstr_loc; _ }, body)
               when pstr_loc.loc_ghost && after e.pexp_loc && contains_registration body ->
               changed := true
             | _ -> ());
            Ast_iterator.default_iterator.expr self e)
      }
    in
    iterator.structure iterator structure;
    not !changed)
;;

(* ---- the file ---- *)

let rewrite ?(early = false) ?(allow_named = false) ~file source =
  match
    let lexbuf = Lexing.from_string source in
    Location.init lexbuf file;
    Parse.implementation lexbuf
  with
  | exception exn ->
    Error (Printf.sprintf "%s: cannot parse: %s" file (Printexc.to_string exn))
  | structure ->
    let edits = ref [] in
    let converted = ref 0 in
    let definitions = ref 0 in
    let named = ref [] in
    let unhandled = ref [] in
    let evaluated_early = ref [] in
    let site_of (e : expression) path note =
      { line = e.pexp_loc.loc_start.pos_lnum; path; note }
    in
    (* Named handlers first: a registration that uses one takes its kind. *)
    let converted_definitions = Hashtbl.create 8 in
    let unsafe_definitions = Hashtbl.create 8 in
    let candidates = ref [] in
    let collector =
      { Ast_iterator.default_iterator with
        structure =
          (fun self items ->
            List.iter
              (fun item ->
                Option.iter
                  (fun candidate -> candidates := candidate :: !candidates)
                  (definition ~allow_early:early ~scope:items source item);
                self.structure_item self item)
              items)
      }
    in
    collector.structure collector structure;
    List.iter
      (fun (definition : definition) ->
        let registrations, occurrences, bindings, earliest_registration, latest_registration, outside_scope, unsafe_registration =
          uses_of_name source structure definition in
        (* The name may be used nowhere else: a handler that other code calls
           with a request and a reqd cannot lose its wrapper. *)
        if registrations > 0 && bindings > 1
        then Hashtbl.replace unsafe_definitions definition.name "named handler has multiple bindings"
        else if registrations > 0 && Option.is_some unsafe_registration
        then Option.iter (Hashtbl.replace unsafe_definitions definition.name) unsafe_registration
        else if registrations > 0 && outside_scope
        then Hashtbl.replace unsafe_definitions definition.name "named handler registration is outside its definition scope"
        else if registrations > 0 && earliest_registration < definition.binding_stop
        then Hashtbl.replace unsafe_definitions definition.name "named handler is registered before its definition"
        else if registrations > 0
                && not (scope_safe_arguments structure definition ~last_registration:latest_registration)
        then Hashtbl.replace unsafe_definitions definition.name "named handler or wrapper argument may resolve differently at registration"
        else if registrations > 0 && definition.unwrapped.partial
                && List.exists (fun argument -> not (is_constant argument)) definition.unwrapped.scope_arguments
        then Hashtbl.replace unsafe_definitions definition.name "named partial wrapper argument would move from the definition to each registration"
        else if registrations > 0 && registrations = occurrences && bindings = 1 && not allow_named
        then Hashtbl.replace unsafe_definitions definition.name "named handler may be used outside this file; external-use review is required"
        else if registrations > 0 && registrations = occurrences && bindings = 1
        then (
          Hashtbl.replace converted_definitions definition.name definition;
          incr definitions;
          named := { line = definition.line; path = definition.name;
                     note = "external-use review required" } :: !named;
          edits :=
            comment_edits source ~anchor:definition.binding_start definition.unwrapped.hoisted
            @ [ { start = definition.name_stop
                ; stop = definition.binding_stop
                ; text = " = " ^ definition.unwrapped.inner_text
                }
              ]
            @ !edits;
          Option.iter
            (fun text ->
              evaluated_early
              := { line = definition.line; path = definition.name; note = text }
                 :: !evaluated_early)
            definition.unwrapped.evaluated_once))
      (List.rev !candidates);
    let iterator =
      { Ast_iterator.default_iterator with
        expr =
          (fun self (e : expression) ->
            (match e.pexp_desc with
             | Pexp_apply (fn, args) ->
               (match registration_function fn with
                | None -> ()
                | Some name ->
                  let site = site_of e (route_path args) in
                  (match registration_function_issue source fn with
                  | Some reason -> unhandled := site reason :: !unhandled
                  | None ->
                  let named_definition =
                    match handler_arg source name args with
                    | Ok (handler, handler_start) ->
                      Option.bind (handler_ident handler) (fun handler_name ->
                        Option.map
                          (fun definition -> definition, handler_start)
                          (Hashtbl.find_opt converted_definitions handler_name))
                    | Error _ -> None
                  in
                  (match named_definition with
                   | Some (definition, handler_start) ->
                     incr converted;
                     let fn_start = fn.pexp_loc.loc_start.pos_cnum in
                     let label =
                       (* [~handler:] goes: [Server_route.add] takes the handler
                          positionally. *)
                       if String.equal name "add"
                       then
                         [ { start = handler_start
                           ; stop = handler_start + String.length handler_label
                           ; text = ""
                           }
                         ]
                       else []
                     in
                     edits :=
                       { start = fn_start
                       ; stop = fn.pexp_loc.loc_end.pos_cnum
                       ; text = Printf.sprintf "Server_route.%s %s" name definition.unwrapped.kind
                       }
                       :: (label @ !edits)
                   | None ->
                     let unsafe =
                       Option.bind (handler_expression name args) (fun handler ->
                         Option.bind (handler_ident handler) (Hashtbl.find_opt unsafe_definitions)) in
                     (match unsafe with
                      | Some reason -> unhandled := site reason :: !unhandled
                      | None -> (match rewrite_registration ~allow_early:early source fn name args with
                      | Ok conversion ->
                        incr converted;
                        edits := conversion.edits @ !edits;
                        Option.iter
                          (fun text -> evaluated_early := site text :: !evaluated_early)
                          conversion.evaluated_once
                      | Error reason -> unhandled := site reason :: !unhandled)))))
             | _ -> ());
            Ast_iterator.default_iterator.expr self e)
      }
    in
    iterator.structure iterator structure;
    (match apply_edits source !edits with
     | exception Failure message -> Error (Printf.sprintf "%s: %s" file message)
     | rewritten ->
       Ok
         ( rewritten
         , { converted = !converted
           ; definitions = !definitions
           ; named = List.rev !named
           ; unhandled = List.rev !unhandled
           ; early = List.rev !evaluated_early
           } ))
;;
