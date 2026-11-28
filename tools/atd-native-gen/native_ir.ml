(* The part of an ATD file that atd-native-gen writes as Swift and Kotlin.

   [of_module] refuses every ATD shape and annotation the emitters do not
   write (RFC-native-keeper-chat-clients D2). An emitter only ever meets the
   shapes below, so it never has to guess what JSON a shape means. *)

module A = Atd.Ast

type scalar =
  | String
  | Int
  | Float
  | Bool
  | Json  (** an abstract type the OCaml side reads as Yojson.Safe.t *)

type ty =
  | Scalar of scalar
  | Ref of string  (** a record or sum defined in the same file *)
  | List of ty

type field =
  { name : string
  ; json_name : string
  ; ty : ty
  ; optional : bool  (** [?x : t option]: absent on the wire when None *)
  }

(* Open: the native type gets an unrecognized case for names this client
   does not know (<native open>). *)
type openness =
  | Closed
  | Open

type enum_case =
  { case_name : string
  ; case_json : string
  }

type tagged_case =
  { tag_name : string
  ; tag_json : string
  ; payload : string  (** the record this kind carries *)
  }

type def =
  | Record of { name : string; fields : field list }
  | Enum of { name : string; cases : enum_case list; openness : openness }
  | Tagged of { name : string; cases : tagged_case list; openness : openness }
      (** one flat object whose "type" names the kind
          (Atdgen_runtime.Json_adapter.Type_field) *)

let type_field_adapter = "Atdgen_runtime.Json_adapter.Type_field"
let ( let* ) = Result.bind

let fail ((start, _) : Atd.Loc.t) fmt =
  Printf.ksprintf
    (fun message ->
      Error (Printf.sprintf "%s:%d: %s" start.Lexing.pos_fname start.pos_lnum message))
    fmt

let rec all = function
  | [] -> Ok []
  | Ok x :: rest ->
    let* rest = all rest in
    Ok (x :: rest)
  | (Error _ as error) :: _ -> error

(* Every annotation field must be in [allowed]. Doc comments never change
   the JSON, so they pass everywhere. *)
let check_annot loc ~allowed (annot : A.annot) =
  let refused =
    List.concat_map
      (fun (section, (_, fields)) ->
        if String.equal section "doc"
        then []
        else
          List.filter_map
            (fun (field, _) ->
              if List.mem (section, field) allowed then None else Some (section, field))
            fields)
      annot
  in
  match refused with
  | [] -> Ok ()
  | (section, field) :: _ -> fail loc "atd-native-gen does not write <%s %s>" section field

let string_field ~section ~field annot =
  Atd.Annot.get_opt_field ~parse:Option.some ~sections:[ section ] ~field annot

(* Wire names go into Swift and Kotlin string literals as they are, so they
   must need no escape there. *)
let plain_name name =
  name <> ""
  && String.for_all
       (function
         | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' -> true
         | _ -> false)
       name

let json_name loc name annot =
  let json = Option.value (string_field ~section:"json" ~field:"name" annot) ~default:name in
  if plain_name json then Ok json else fail loc "wire name %S must be ASCII letters, digits and _" json

let openness annot =
  if Atd.Annot.get_flag ~sections:[ "native" ] ~field:"open" annot then Open else Closed

let local_name loc (A.TN path) =
  match path with
  | [ name ] -> Ok name
  | _ -> fail loc "imported type %s is not written" (String.concat "." path)

let rec ty ~json_aliases (expr : A.type_expr) =
  match expr with
  | Name (loc, (_, type_name, args), annot) ->
    let* () = check_annot loc ~allowed:[] annot in
    let* name = local_name loc type_name in
    (match name, args with
     | _, _ :: _ -> fail loc "type parameters are not written: %s" name
     | "string", [] -> Ok (Scalar String)
     | "int", [] -> Ok (Scalar Int)
     | "float", [] -> Ok (Scalar Float)
     | "bool", [] -> Ok (Scalar Bool)
     | ("unit" | "abstract"), [] -> fail loc "%s is not written; name an abstract json type" name
     | _, [] -> if List.mem name json_aliases then Ok (Scalar Json) else Ok (Ref name))
  | List (loc, item, annot) ->
    let* () = check_annot loc ~allowed:[] annot in
    let* item = ty ~json_aliases item in
    Ok (List item)
  | Option (loc, _, _) -> fail loc "option is written only as an optional field (?x : t option)"
  | Sum (loc, _, _) | Record (loc, _, _) -> fail loc "inline sums and records are not written; name them"
  | Tuple (loc, _, _) -> fail loc "tuples are not written"
  | Nullable (loc, _, _) -> fail loc "nullable is not written"
  | Shared (loc, _, _) | Wrap (loc, _, _) -> fail loc "shared and wrap are not written"
  | Tvar (loc, name) -> fail loc "type variable '%s is not written" name

let field ~json_aliases (field : A.field) =
  match field with
  | Inherit (loc, _) -> fail loc "inherit must be expanded when the file is loaded"
  | Field (loc, (name, kind, annot), expr) ->
    let* () = check_annot loc ~allowed:[ "json", "name" ] annot in
    let* json_name = json_name loc name annot in
    (match kind with
     | Required ->
       let* ty = ty ~json_aliases expr in
       Ok { name; json_name; ty; optional = false }
     | Optional ->
       (match expr with
        | Option (option_loc, inner, option_annot) ->
          let* () = check_annot option_loc ~allowed:[] option_annot in
          let* ty = ty ~json_aliases inner in
          Ok { name; json_name; ty; optional = true }
        | Name _ | Sum _ | Record _ | Tuple _ | List _ | Nullable _ | Shared _ | Wrap _ | Tvar _ ->
          fail loc "optional field %s must have type t option" name)
     | With_default -> fail loc "default field ~%s is not written" name)

let variant (variant : A.variant) =
  match variant with
  | Inherit (loc, _) -> fail loc "inherit must be expanded when the file is loaded"
  | Variant (loc, (name, annot), payload) ->
    let* () = check_annot loc ~allowed:[ "json", "name" ] annot in
    let* json = json_name loc name annot in
    Ok (loc, name, json, payload)

let enum_case (loc, name, json, payload) =
  match payload with
  | None -> Ok { case_name = name; case_json = json }
  | Some _ ->
    fail loc "%s has a payload; a sum with payloads needs <json adapter.ocaml=%S>" name
      type_field_adapter

let tagged_case (loc, name, json, payload) =
  let refuse () = fail loc "%s must carry a named record under %s" name type_field_adapter in
  match payload with
  | None -> refuse ()
  | Some (A.Name (_, (_, type_name, args), annot)) ->
    (match args, annot with
     | [], [] ->
       let* record = local_name loc type_name in
       Ok { tag_name = name; tag_json = json; payload = record }
     | _ :: _, _ | [], _ :: _ -> refuse ())
  | Some (Sum _ | Record _ | Tuple _ | List _ | Option _ | Nullable _ | Shared _ | Wrap _ | Tvar _) ->
    refuse ()

let sum ~name loc variants annot =
  let* () =
    check_annot loc
      ~allowed:[ "ocaml", "repr"; "json", "adapter.ocaml"; "native", "open" ]
      annot
  in
  let* variants = all (List.map variant variants) in
  let openness = openness annot in
  match string_field ~section:"json" ~field:"adapter.ocaml" annot with
  | None ->
    let* cases = all (List.map enum_case variants) in
    Ok (Enum { name; cases; openness })
  | Some adapter when String.equal adapter type_field_adapter ->
    let* cases = all (List.map tagged_case variants) in
    Ok (Tagged { name; cases; openness })
  | Some adapter -> fail loc "adapter %s is not written; only %s" adapter type_field_adapter

(* [type json <ocaml module="Yojson.Safe" t="t"> = abstract]: any JSON value. *)
let is_json_alias (def : A.type_def) =
  match def.value with
  | Name (_, (_, TN path, args), _) ->
    path = [ "abstract" ] && args = []
    && string_field ~section:"ocaml" ~field:"module" def.annot = Some "Yojson.Safe"
    && string_field ~section:"ocaml" ~field:"t" def.annot = Some "t"
  | Sum _ | Record _ | Tuple _ | List _ | Option _ | Nullable _ | Shared _ | Wrap _ | Tvar _ ->
    false

let def ~json_aliases (def : A.type_def) =
  let* name = local_name def.loc def.name in
  let* () = if def.param = [] then Ok () else fail def.loc "parametric type %s is not written" name in
  let* () = check_annot def.loc ~allowed:[] def.annot in
  match def.value with
  | Record (loc, fields, annot) ->
    let* () = check_annot loc ~allowed:[] annot in
    let* fields = all (List.map (field ~json_aliases) fields) in
    Ok (Record { name; fields })
  | Sum (loc, variants, annot) -> sum ~name loc variants annot
  | Name _ | Tuple _ | List _ | Option _ | Nullable _ | Shared _ | Wrap _ | Tvar _ ->
    fail def.loc "%s must be a record or a sum" name

let records defs =
  List.filter_map
    (function
      | Record { name; _ } -> Some name
      | Enum _ | Tagged _ -> None)
    defs

let check_payloads defs =
  let records = records defs in
  all
    (List.concat_map
       (function
         | Tagged { name; cases; _ } ->
           List.map
             (fun case ->
               if List.mem case.payload records
               then Ok ()
               else
                 Error
                   (Printf.sprintf "%s.%s carries %s, which is not a record" name case.tag_name
                      case.payload))
             cases
         | Record _ | Enum _ -> [])
       defs)

let of_module (atd : A.module_) =
  let* () =
    match atd.imports with
    | [] -> Ok ()
    | import :: _ -> fail import.loc "imports are not written"
  in
  let json_defs, other_defs = List.partition is_json_alias atd.type_defs in
  let* json_aliases =
    all (List.map (fun (d : A.type_def) -> local_name d.loc d.name) json_defs)
  in
  let* defs = all (List.map (def ~json_aliases) other_defs) in
  let* _ = check_payloads defs in
  Ok defs

let uses_json defs =
  let rec ty_uses = function
    | Scalar Json -> true
    | Scalar (String | Int | Float | Bool) | Ref _ -> false
    | List item -> ty_uses item
  in
  List.exists
    (function
      | Record { fields; _ } -> List.exists (fun field -> ty_uses field.ty) fields
      | Tagged { openness = Open; _ } -> true
      | Tagged { openness = Closed; _ } | Enum _ -> false)
    defs
