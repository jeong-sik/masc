open Parsetree
module String_map = Map.Make (String)
module String_set = Set.Make (String)

let parse_interface path =
  let channel = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in channel)
    (fun () ->
       let lexbuf = Lexing.from_channel channel in
       Location.init lexbuf path;
       Parse.interface lexbuf)
;;

let parse_implementation path =
  let channel = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in channel)
    (fun () ->
       let lexbuf = Lexing.from_channel channel in
       Location.init lexbuf path;
       Parse.implementation lexbuf)
;;

let longident_parts identifier =
  try Ok (Longident.flatten identifier) with
  | Invalid_argument _ -> Error ()
;;

let count_qualified_calls qualified structure =
  let expected = String.split_on_char '.' qualified in
  let count = ref 0 in
  let iterator =
    { Ast_iterator.default_iterator with
      expr =
        (fun self expression ->
          (match expression.pexp_desc with
           | Pexp_apply ({ pexp_desc = Pexp_ident identifier; _ }, _) ->
             (match longident_parts identifier.txt with
              | Ok actual when List.equal String.equal actual expected -> incr count
              | Ok _ | Error () -> ())
           | _ -> ());
          Ast_iterator.default_iterator.expr self expression)
    }
  in
  iterator.structure iterator structure;
  !count
;;

type alias_index =
  { manifests : core_type String_map.t
  ; ambiguous : String_set.t
  ; local_modules : String_set.t
  }

let alias_index signature =
  let manifests = ref String_map.empty in
  let ambiguous = ref String_set.empty in
  let local_modules = ref String_set.empty in
  let add_manifest name manifest =
    if String_set.mem name !ambiguous
    then ()
    else if String_map.mem name !manifests
    then (
      manifests := String_map.remove name !manifests;
      ambiguous := String_set.add name !ambiguous)
    else manifests := String_map.add name manifest !manifests
  in
  let add_module declaration =
    match declaration.pmd_name.txt with
    | Some name -> local_modules := String_set.add name !local_modules
    | None -> ()
  in
  let iterator =
    { Ast_iterator.default_iterator with
      signature_item =
        (fun self item ->
          (match item.psig_desc with
           | Psig_type (_, declarations) ->
             List.iter
               (fun declaration ->
                  Option.iter
                    (add_manifest declaration.ptype_name.txt)
                    declaration.ptype_manifest)
               declarations
           | Psig_module declaration -> add_module declaration
           | Psig_recmodule declarations -> List.iter add_module declarations
           | _ -> ());
          Ast_iterator.default_iterator.signature_item self item)
    }
  in
  iterator.signature iterator signature;
  { manifests = !manifests; ambiguous = !ambiguous; local_modules = !local_modules }
;;

let trusted_qualified_argument_types =
  List.fold_left
    (fun trusted name -> String_set.add name trusted)
    String_set.empty
    [ "Eio.Buf_read.t"
    ; "Eio.Net.ty"
    ; "Eio.Resource.t"
    ; "Eio.Switch.t"
    ; "Eio.Time.clock"
    ; "Llm_transport.completion_request"
    ; "Provider_config.t"
    ; "Types.message"
    ; "Types.stop_reason"
    ; "Yojson.Safe.t"
    ]
;;

let type_facts core_type =
  let contains_arrow = ref false in
  let references = ref [] in
  let unresolved = ref false in
  let iterator =
    { Ast_iterator.default_iterator with
      typ =
        (fun self current ->
          (match current.ptyp_desc with
           | Ptyp_arrow _ -> contains_arrow := true
           | Ptyp_constr ({ txt = identifier; _ }, _) ->
             (match longident_parts identifier with
              | Ok parts -> references := parts :: !references
              | Error () -> unresolved := true)
           | _ -> ());
          Ast_iterator.default_iterator.typ self current)
    }
  in
  iterator.typ iterator core_type;
  !contains_arrow, !references, !unresolved
;;

let type_contains_callback index core_type =
  let rec inspect visiting current =
    let contains_arrow, references, unresolved = type_facts current in
    contains_arrow
    || unresolved
    || List.exists
         (fun parts ->
            match parts with
            | [ name ] ->
              if String_set.mem name index.ambiguous
              then true
              else if String_set.mem name visiting
              then false
              else (
                match String_map.find_opt name index.manifests with
                | Some manifest -> inspect (String_set.add name visiting) manifest
                | None -> false)
            | local_module :: _ :: _ ->
              String_set.mem local_module index.local_modules
              || not
                   (String_set.mem
                      (String.concat "." parts)
                      trusted_qualified_argument_types)
            | _ ->
              not
                (String_set.mem
                   (String.concat "." parts)
                   trusted_qualified_argument_types))
         references
  in
  inspect String_set.empty core_type
;;

let label_fingerprint = function
  | Asttypes.Nolabel -> "_"
  | Asttypes.Labelled label -> "~" ^ label
  | Asttypes.Optional label -> "?" ^ label
;;

let rec type_fingerprint index visiting core_type =
  match core_type.ptyp_desc with
  | Ptyp_any -> "any"
  | Ptyp_var name -> "var(" ^ name ^ ")"
  | Ptyp_arrow (label, argument, result) ->
    Printf.sprintf
      "arrow(%s,%s,%s)"
      (label_fingerprint label)
      (type_fingerprint index visiting argument)
      (type_fingerprint index visiting result)
  | Ptyp_constr ({ txt = identifier; _ }, arguments) ->
    (match longident_parts identifier with
     | Ok [ name ]
       when arguments = []
            && (not (String_set.mem name index.ambiguous))
            && not (String_set.mem name visiting) ->
       (match String_map.find_opt name index.manifests with
        | Some manifest -> type_fingerprint index (String_set.add name visiting) manifest
        | None -> "constr(" ^ name ^ ")")
     | Ok parts ->
       let suffix =
         match arguments with
         | [] -> ""
         | _ ->
           "," ^ String.concat "," (List.map (type_fingerprint index visiting) arguments)
       in
       "constr(" ^ String.concat "." parts ^ suffix ^ ")"
     | Error () -> "unresolved-longident")
  | _ ->
    "syntax(" ^ String.escaped (Format.asprintf "%a" Pprintast.core_type core_type) ^ ")"
;;

let rec argument_types reversed = function
  | { ptyp_desc = Ptyp_arrow (label, argument, result); _ } ->
    argument_types ((label, argument) :: reversed) result
  | _ -> List.rev reversed
;;

type violation_kind =
  | Callback_argument
  | Unresolved_public_surface of string

type violation =
  { path : string
  ; value_name : string
  ; argument_label : string
  ; type_fingerprint : string
  ; kind : violation_kind
  }

let callback_values path signature =
  let index = alias_index signature in
  let violations = ref [] in
  let add_callback value_name label core_type =
    violations
    := { path
       ; value_name
       ; argument_label = label_fingerprint label
       ; type_fingerprint = type_fingerprint index String_set.empty core_type
       ; kind = Callback_argument
       }
       :: !violations
  in
  let add_surface value_name detail =
    violations
    := { path
       ; value_name
       ; argument_label = "<surface>"
       ; type_fingerprint = "<unresolved>"
       ; kind = Unresolved_public_surface detail
       }
       :: !violations
  in
  let observe_module declaration =
    match declaration.pmd_type.pmty_desc with
    | Pmty_signature _ -> ()
    | _ ->
      add_surface
        (match declaration.pmd_name.txt with
         | Some name -> name
         | None -> "<anonymous-module>")
        "non-inline module type, alias, typeof, or with-constraint"
  in
  let iterator =
    { Ast_iterator.default_iterator with
      signature_item =
        (fun self item ->
          (match item.psig_desc with
           | Psig_value description ->
             List.iter
               (fun (label, argument) ->
                  if type_contains_callback index argument
                  then add_callback description.pval_name.txt label argument)
               (argument_types [] description.pval_type)
           | Psig_module declaration -> observe_module declaration
           | Psig_recmodule declarations -> List.iter observe_module declarations
           | Psig_include _ ->
             add_surface
               "<include>"
               "public include or include module type of is not expanded"
           | Psig_open _ ->
             add_surface "<signature-open>" "public signature open is not expanded"
           | _ -> ());
          Ast_iterator.default_iterator.signature_item self item)
    }
  in
  iterator.signature iterator signature;
  List.rev !violations
;;

let violation_key violation =
  String.concat
    "|"
    [ Filename.basename violation.path
    ; violation.value_name
    ; violation.argument_label
    ; violation.type_fingerprint
    ]
;;

let add_allowed_fingerprint fingerprint allowed =
  String_map.update
    fingerprint
    (function
      | None -> Some 1
      | Some count -> Some (count + 1))
    allowed
;;

let report violation =
  match violation.kind with
  | Callback_argument ->
    prerr_endline
      (Printf.sprintf
         "%s: public value %s argument %s accepts callback-bearing or unresolved type %s"
         violation.path
         violation.value_name
         violation.argument_label
         violation.type_fingerprint)
  | Unresolved_public_surface detail ->
    prerr_endline
      (Printf.sprintf
         "%s: public surface %s is unresolved (%s)"
         violation.path
         violation.value_name
         detail)
;;

let identifier_is expected identifier =
  match longident_parts identifier with
  | Ok actual -> List.equal String.equal actual expected
  | Error () -> false
;;

let direct_call_to expected expression =
  match expression.pexp_desc with
  | Pexp_apply ({ pexp_desc = Pexp_ident identifier; _ }, _) ->
    identifier_is expected identifier.txt
  | _ -> false
;;

let field_call_to expected expression =
  match expression.pexp_desc with
  | Pexp_apply ({ pexp_desc = Pexp_field (_, { txt = Longident.Lident field; _ }); _ }, _)
    -> String.equal field expected
  | _ -> false
;;

let call_positions predicate expression =
  let positions = ref [] in
  let iterator =
    { Ast_iterator.default_iterator with
      expr =
        (fun self current ->
          if predicate current
          then positions := current.pexp_loc.loc_start.pos_cnum :: !positions;
          Ast_iterator.default_iterator.expr self current)
    }
  in
  iterator.expr iterator expression;
  List.sort Int.compare !positions
;;

let top_level_binding name structure =
  List.find_map
    (fun item ->
       match item.pstr_desc with
       | Pstr_value (_, bindings) ->
         List.find_map
           (fun binding ->
              match binding.pvb_pat.ppat_desc with
              | Ppat_var bound when String.equal bound.txt name -> Some binding.pvb_expr
              | _ -> None)
           bindings
       | _ -> None)
    structure
;;

let exact_post_path = [ "Cohttp_eio"; "Client"; "post" ]

type transport_scope =
  { modules : String_set.t
  ; module_aliases : string list String_map.t
  ; values : String_set.t
  ; value_aliases : string list String_map.t
  }

let rec transparent_expression expression =
  match expression.pexp_desc with
  | Pexp_constraint (inner, _) | Pexp_coerce (inner, _, _) | Pexp_poly (inner, _) ->
    transparent_expression inner
  | _ -> expression
;;

let rec transparent_module_expression module_expression =
  match module_expression.pmod_desc with
  | Pmod_constraint (inner, _) -> transparent_module_expression inner
  | _ -> module_expression
;;

let rec transparent_pattern pattern =
  match pattern.ppat_desc with
  | Ppat_constraint (inner, _) -> transparent_pattern inner
  | _ -> pattern
;;

let transport_scope structure =
  let add_module scope declaration =
    match declaration.pmb_name.txt with
    | None -> scope
    | Some name ->
      let module_aliases =
        match (transparent_module_expression declaration.pmb_expr).pmod_desc with
        | Pmod_ident identifier ->
          (match longident_parts identifier.txt with
           | Ok parts -> String_map.add name parts scope.module_aliases
           | Error () -> scope.module_aliases)
        | _ -> scope.module_aliases
      in
      { scope with modules = String_set.add name scope.modules; module_aliases }
  in
  let add_value scope binding =
    match (transparent_pattern binding.pvb_pat).ppat_desc with
    | Ppat_var name ->
      let value_aliases =
        match (transparent_expression binding.pvb_expr).pexp_desc with
        | Pexp_ident identifier ->
          (match longident_parts identifier.txt with
           | Ok parts -> String_map.add name.txt parts scope.value_aliases
           | Error () -> scope.value_aliases)
        | _ -> scope.value_aliases
      in
      { scope with values = String_set.add name.txt scope.values; value_aliases }
    | _ -> scope
  in
  List.fold_left
    (fun scope item ->
       match item.pstr_desc with
       | Pstr_module declaration -> add_module scope declaration
       | Pstr_recmodule declarations -> List.fold_left add_module scope declarations
       | Pstr_value (_, bindings) -> List.fold_left add_value scope bindings
       | _ -> scope)
    { modules = String_set.empty
    ; module_aliases = String_map.empty
    ; values = String_set.empty
    ; value_aliases = String_map.empty
    }
    structure
;;

type transport_reference =
  | Local_transport_reference
  | External_transport_reference of string list
  | Unresolved_transport_reference

let transport_reference_facts structure =
  let exact_references = ref 0 in
  let post_calls = ref 0 in
  let unresolved_identifiers = ref 0 in
  let forbidden_module_alias = ref false in
  let external_proxy_or_reexport = ref false in
  let external_value_alias = ref false in
  let scopes = ref [] in
  let visible_name select name =
    List.exists (fun scope -> String_set.mem name (select scope)) !scopes
  in
  let rec visible_alias select name = function
    | [] -> None
    | scope :: rest ->
      (match String_map.find_opt name (select scope) with
       | Some target -> Some target
       | None -> visible_alias select name rest)
  in
  let ends_in_post = function
    | parts ->
      (match List.rev parts with
       | "post" :: _ -> true
       | _ -> false)
  in
  let rec resolve_module seen = function
    | [] -> Unresolved_transport_reference
    | root :: suffix as parts ->
      if String_set.mem root seen
      then Unresolved_transport_reference
      else (
        match visible_alias (fun scope -> scope.module_aliases) root !scopes with
        | Some target -> resolve_module (String_set.add root seen) (target @ suffix)
        | None ->
          if visible_name (fun scope -> scope.modules) root
          then Local_transport_reference
          else External_transport_reference parts)
  in
  let rec resolve_value seen = function
    | [] -> Unresolved_transport_reference
    | [ name ] as parts ->
      if String_set.mem name seen
      then Unresolved_transport_reference
      else (
        match visible_alias (fun scope -> scope.value_aliases) name !scopes with
        | Some target -> resolve_value (String_set.add name seen) target
        | None ->
          if visible_name (fun scope -> scope.values) name
          then Local_transport_reference
          else External_transport_reference parts)
    | parts -> resolve_module String_set.empty parts
  in
  let resolve_identifier identifier =
    match longident_parts identifier with
    | Ok parts -> resolve_value String_set.empty parts
    | Error () -> Unresolved_transport_reference
  in
  let cohttp_eio_reference = function
    | External_transport_reference ("Cohttp_eio" :: _) -> true
    | Local_transport_reference
    | External_transport_reference _
    | Unresolved_transport_reference -> false
  in
  let external_module_reference identifier =
    match longident_parts identifier with
    | Ok parts -> resolve_module String_set.empty parts
    | Error () -> Unresolved_transport_reference
  in
  let external_post_reference expression =
    match (transparent_expression expression).pexp_desc with
    | Pexp_ident identifier ->
      (match resolve_identifier identifier.txt with
       | External_transport_reference parts -> ends_in_post parts
       | Unresolved_transport_reference -> true
       | Local_transport_reference -> false)
    | _ -> false
  in
  let inspect_value_bindings bindings =
    if List.exists (fun binding -> external_post_reference binding.pvb_expr) bindings
    then external_value_alias := true
  in
  let iterator =
    { Ast_iterator.default_iterator with
      expr =
        (fun self expression ->
          (match expression.pexp_desc with
           | Pexp_apply (callee, _) ->
             (match (transparent_expression callee).pexp_desc with
              | Pexp_ident identifier ->
                (match resolve_identifier identifier.txt with
                 | External_transport_reference parts when ends_in_post parts ->
                   (match longident_parts identifier.txt with
                    | Ok (root :: _)
                      when Option.is_some
                             (visible_alias
                                (fun scope -> scope.module_aliases)
                                root
                                !scopes) -> external_proxy_or_reexport := true
                    | Ok _ | Error () -> ());
                   incr post_calls
                 | Unresolved_transport_reference -> incr unresolved_identifiers
                 | Local_transport_reference | External_transport_reference _ -> ())
              | _ -> ())
           | Pexp_let (_, bindings, _) -> inspect_value_bindings bindings
           | Pexp_ident identifier ->
             (match resolve_identifier identifier.txt with
              | External_transport_reference actual
                when List.equal String.equal actual exact_post_path ->
                incr exact_references
              | Unresolved_transport_reference -> incr unresolved_identifiers
              | Local_transport_reference | External_transport_reference _ -> ())
           | _ -> ());
          Ast_iterator.default_iterator.expr self expression)
    ; module_expr =
        (fun self module_expression ->
          (match (transparent_module_expression module_expression).pmod_desc with
           | Pmod_ident identifier ->
             (match external_module_reference identifier.txt with
              | reference when cohttp_eio_reference reference ->
                forbidden_module_alias := true
              | Unresolved_transport_reference -> incr unresolved_identifiers
              | Local_transport_reference | External_transport_reference _ -> ())
           | _ -> ());
          Ast_iterator.default_iterator.module_expr self module_expression)
    ; structure_item =
        (fun self item ->
          (match item.pstr_desc with
           | Pstr_include declaration ->
             (match (transparent_module_expression declaration.pincl_mod).pmod_desc with
              | Pmod_ident identifier ->
                (match external_module_reference identifier.txt with
                 | Local_transport_reference -> ()
                 | reference when cohttp_eio_reference reference ->
                   forbidden_module_alias := true
                 | External_transport_reference _ -> external_proxy_or_reexport := true
                 | Unresolved_transport_reference -> incr unresolved_identifiers)
              | _ -> ())
           | Pstr_value (_, bindings) -> inspect_value_bindings bindings
           | _ -> ());
          Ast_iterator.default_iterator.structure_item self item)
    ; structure =
        (fun self items ->
          scopes := transport_scope items :: !scopes;
          Fun.protect
            ~finally:(fun () -> scopes := List.tl !scopes)
            (fun () -> Ast_iterator.default_iterator.structure self items))
    }
  in
  iterator.structure iterator structure;
  ( !exact_references
  , !post_calls
  , !unresolved_identifiers
  , !forbidden_module_alias
  , !external_proxy_or_reexport
  , !external_value_alias )
;;

let stage2_chain_is_direct expression =
  let found = ref false in
  let contains_dispatch_cas guard =
    call_positions (direct_call_to [ "Atomic"; "compare_and_set" ]) guard <> []
  in
  let tail_starts_with_post = function
    | { pexp_desc = Pexp_let (_, bindings, _); _ } ->
      List.exists
        (fun binding -> direct_call_to exact_post_path binding.pvb_expr)
        bindings
    | _ -> false
  in
  let iterator =
    { Ast_iterator.default_iterator with
      expr =
        (fun self current ->
          (match current.pexp_desc with
           | Pexp_sequence (guard, { pexp_desc = Pexp_sequence (mark, tail); _ })
             when contains_dispatch_cas guard
                  && field_call_to "mark_dispatch_started" mark
                  && tail_starts_with_post tail -> found := true
           | _ -> ());
          Ast_iterator.default_iterator.expr self current)
    }
  in
  iterator.expr iterator expression;
  !found
;;

type exact_transport_violation_category =
  | Unresolved_applied_identifier
  | Forbidden_cohttp_alias
  | External_transport_reexport
  | External_post_value_alias
  | Unexpected_post_call_count
  | Noncanonical_post_reference
  | Noncanonical_transport_order
  | Missing_transport_entrypoints

type exact_transport_violation =
  { category : exact_transport_violation_category
  ; detail : string
  }

let exact_transport_violation category detail = Some { category; detail }

let exact_transport_violation_category_name = function
  | Unresolved_applied_identifier -> "unresolved-applied-identifier"
  | Forbidden_cohttp_alias -> "forbidden-cohttp-alias"
  | External_transport_reexport -> "external-transport-reexport"
  | External_post_value_alias -> "external-post-value-alias"
  | Unexpected_post_call_count -> "unexpected-post-call-count"
  | Noncanonical_post_reference -> "noncanonical-post-reference"
  | Noncanonical_transport_order -> "noncanonical-transport-order"
  | Missing_transport_entrypoints -> "missing-transport-entrypoints"
;;

let exact_transport_violation_category_of_name name =
  List.find_opt
    (fun category -> String.equal name (exact_transport_violation_category_name category))
    [ Unresolved_applied_identifier
    ; Forbidden_cohttp_alias
    ; External_transport_reexport
    ; External_post_value_alias
    ; Unexpected_post_call_count
    ; Noncanonical_post_reference
    ; Noncanonical_transport_order
    ; Missing_transport_entrypoints
    ]
;;

let exact_transport_error path structure =
  let ( exact_references
      , post_calls
      , unresolved_identifiers
      , forbidden_module_alias
      , external_proxy_or_reexport
      , external_value_alias )
    =
    transport_reference_facts structure
  in
  let direct_post_calls = count_qualified_calls "Cohttp_eio.Client.post" structure in
  if unresolved_identifiers <> 0
  then
    exact_transport_violation
      Unresolved_applied_identifier
      (Printf.sprintf "%s: unresolved applied identifier in private transport" path)
  else if forbidden_module_alias
  then
    exact_transport_violation
      Forbidden_cohttp_alias
      (Printf.sprintf "%s: Cohttp_eio module alias/open/include is forbidden" path)
  else if external_proxy_or_reexport
  then
    exact_transport_violation
      External_transport_reexport
      (Printf.sprintf "%s: external transport proxy/reexport is forbidden" path)
  else if external_value_alias
  then
    exact_transport_violation
      External_post_value_alias
      (Printf.sprintf "%s: external post value alias is forbidden" path)
  else if post_calls <> 1
  then
    exact_transport_violation
      Unexpected_post_call_count
      (Printf.sprintf "%s: expected one post call, found %d" path post_calls)
  else if exact_references <> 1 || direct_post_calls <> 1
  then
    exact_transport_violation
      Noncanonical_post_reference
      (Printf.sprintf
         "%s: expected one qualified post reference and one direct call, found %d/%d"
         path
         exact_references
         direct_post_calls)
  else (
    match
      ( top_level_binding "post_sync_once" structure
      , top_level_binding "post_sync_once_after_commit" structure )
    with
    | Some admission, Some transport ->
      let positions target expression = call_positions target expression in
      let resolve =
        positions
          (direct_call_to [ "Http_client"; "resolve_explicit_deadline" ])
          admission
      in
      let validate_uri = positions (direct_call_to [ "validate_uri" ]) admission in
      let validate_body =
        positions (direct_call_to [ "validate_headers_and_body" ]) admission
      in
      let commit_cas =
        positions (direct_call_to [ "Atomic"; "compare_and_set" ]) admission
      in
      let commit = positions (field_call_to "commit_fence") admission in
      let delegate =
        positions (direct_call_to [ "post_sync_once_after_commit" ]) admission
      in
      let connect = positions (direct_call_to [ "make_connection" ]) transport in
      let dispatch_cas =
        positions (direct_call_to [ "Atomic"; "compare_and_set" ]) transport
      in
      let mark = positions (field_call_to "mark_dispatch_started") transport in
      let post = positions (direct_call_to exact_post_path) transport in
      (match
         ( resolve
         , validate_uri
         , validate_body
         , commit_cas
         , commit
         , delegate
         , connect
         , dispatch_cas
         , mark
         , post )
       with
       | ( [ resolve_connect; resolve_body ]
         , [ validate_uri ]
         , [ validate_body ]
         , [ commit_cas ]
         , [ commit ]
         , [ delegate ]
         , [ connect ]
         , [ dispatch_cas ]
         , [ mark ]
         , [ post ] )
         when resolve_connect < resolve_body
              && resolve_body < validate_uri
              && validate_uri < validate_body
              && validate_body < commit_cas
              && commit_cas < commit
              && commit < delegate
              && connect < dispatch_cas
              && dispatch_cas < mark
              && mark < post
              && stage2_chain_is_direct transport -> None
       | _ ->
         exact_transport_violation
           Noncanonical_transport_order
           (Printf.sprintf
              "%s: validation, durable commit, connect, CAS/mark, and POST order is not \
               canonical"
              path))
    | _ ->
      exact_transport_violation
        Missing_transport_entrypoints
        (Printf.sprintf
           "%s: exact transport must define post_sync_once and \
            post_sync_once_after_commit"
           path))
;;

let parse_transport path =
  try Ok (parse_implementation path) with
  | Sys_error detail -> Error detail
  | Syntaxerr.Error _ -> Error ("syntax error while parsing " ^ path)
;;

let () =
  match Array.to_list Sys.argv with
  | [ _; "--check-exact-transport"; path ] ->
    (match parse_transport path with
     | Error detail ->
       prerr_endline detail;
       exit 2
     | Ok structure ->
       (match exact_transport_error path structure with
        | None -> ()
        | Some violation ->
          prerr_endline violation.detail;
          exit 1))
  | [ _; "--expect-exact-transport-violation"; category_name; path ] ->
    (match exact_transport_violation_category_of_name category_name with
     | None ->
       prerr_endline
         (Printf.sprintf "unknown exact transport violation category: %s" category_name);
       exit 2
     | Some expected_category ->
       (match parse_transport path with
        | Error detail ->
          prerr_endline detail;
          exit 2
        | Ok structure ->
          (match exact_transport_error path structure with
           | Some { category; _ } when category = expected_category -> ()
           | Some violation ->
             prerr_endline
               (Printf.sprintf
                  "expected exact transport violation %s, got %s: %s"
                  category_name
                  (exact_transport_violation_category_name violation.category)
                  violation.detail);
             exit 1
           | None ->
             prerr_endline "negative transport fixture no longer violates the boundary";
             exit 1)))
  | [ _; "--expect-exact-transport-violation"; path ] ->
    (match parse_transport path with
     | Error detail ->
       prerr_endline detail;
       exit 2
     | Ok structure ->
       (match exact_transport_error path structure with
        | Some _ -> ()
        | None ->
          prerr_endline "negative transport fixture no longer violates the boundary";
          exit 1))
  | _ :: arguments ->
    let rec parse allow expect paths = function
      | [] -> allow, expect, List.rev paths
      | "--allow-callback-in" :: interface :: fingerprint :: rest ->
        let allowance_key =
          String.concat "|" [ Filename.basename interface; fingerprint ]
        in
        parse (add_allowed_fingerprint allowance_key allow) expect paths rest
      | "--allow-callback" :: _ ->
        prerr_endline
          "--allow-callback requires an owning interface; use --allow-callback-in";
        exit 2
      | "--allow" :: _ ->
        prerr_endline
          "--allow is forbidden: allow an exact interface|value|label|resolved-type \
           fingerprint";
        exit 2
      | "--expect-callback" :: rest -> parse allow true paths rest
      | path :: rest -> parse allow expect (path :: paths) rest
    in
    let allow, expect_callback, paths = parse String_map.empty false [] arguments in
    if paths = []
    then (
      prerr_endline "usage: check_public_mli_callbacks [flags] <interface>...";
      exit 2);
    let _ =
      List.fold_left
        (fun basenames path ->
           let basename = Filename.basename path in
           if String_set.mem basename basenames
           then (
             prerr_endline
               (Printf.sprintf
                  "duplicate interface basename in one invocation: %s"
                  basename);
             exit 2)
           else String_set.add basename basenames)
        String_set.empty
        paths
    in
    let callbacks =
      List.concat_map
        (fun path ->
           try callback_values path (parse_interface path) with
           | Sys_error detail ->
             prerr_endline detail;
             exit 2
           | Syntaxerr.Error _ ->
             prerr_endline ("syntax error while parsing " ^ path);
             exit 2)
        paths
    in
    let remaining_allow = ref allow in
    let consume_allow fingerprint =
      match String_map.find_opt fingerprint !remaining_allow with
      | None -> false
      | Some 1 ->
        remaining_allow := String_map.remove fingerprint !remaining_allow;
        true
      | Some count ->
        remaining_allow := String_map.add fingerprint (count - 1) !remaining_allow;
        true
    in
    let violations =
      List.filter
        (fun violation ->
           match violation.kind with
           | Callback_argument -> not (consume_allow (violation_key violation))
           | Unresolved_public_surface _ -> true)
        callbacks
    in
    if not (String_map.is_empty !remaining_allow)
    then (
      String_map.iter
        (fun fingerprint count ->
           prerr_endline
             (Printf.sprintf "unused callback allowance (%d): %s" count fingerprint))
        !remaining_allow;
      exit 1)
    else if expect_callback
    then (
      if violations = []
      then (
        prerr_endline "negative fixture did not expose a callback-bearing public value";
        exit 1))
    else if violations <> []
    then (
      List.iter report violations;
      exit 1)
  | [] -> assert false
;;
