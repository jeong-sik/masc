(* Native_ir takes the Keeper chat wire as it is, and refuses every shape
   and annotation the emitters do not write (RFC-native-keeper-chat-clients
   D2) instead of writing something close to it. *)

open Atd_native

let load_string text =
  Atd.Util.load_string ~inherit_fields:true ~inherit_variants:true ~pos_fname:"case.atd" text

let wire () =
  Atd.Util.load_file ~inherit_fields:true ~inherit_variants:true
    "../../lib/keeper_chat_wire/keeper_chat_wire.atd"

let find_def name defs =
  List.find_opt
    (fun (def : Native_ir.def) ->
      match def with
      | Record { name = n; _ } | Enum { name = n; _ } | Tagged { name = n; _ } -> String.equal n name)
    defs

(* Cases per sum and fields per record (inherit expanded) in the ATD. *)
let ast_sizes (atd : Atd.Ast.module_) =
  List.filter_map
    (fun (def : Atd.Ast.type_def) ->
      let (TN path) = def.name in
      let name = String.concat "." path in
      match def.value with
      | Sum (_, variants, _) -> Some (name, List.length variants)
      | Record (_, fields, _) -> Some (name, List.length fields)
      | Name _ | Tuple _ | List _ | Option _ | Nullable _ | Shared _ | Wrap _ | Tvar _ -> None)
    atd.type_defs

let ir_size : Native_ir.def -> int = function
  | Record { fields; _ } -> List.length fields
  | Enum { cases; _ } -> List.length cases
  | Tagged { cases; _ } -> List.length cases

let test_wire_is_taken () =
  let atd = wire () in
  match Native_ir.of_module atd with
  | Error message -> Alcotest.fail message
  | Ok defs ->
    let sizes = ast_sizes atd in
    Alcotest.(check int) "one definition per ATD record and sum" (List.length sizes) (List.length defs);
    List.iter
      (fun (name, size) ->
        match find_def name defs with
        | Some def -> Alcotest.(check int) ("every case and field of " ^ name) size (ir_size def)
        | None -> Alcotest.failf "%s is missing" name)
      sizes;
    (match find_def "frame" defs with
     | Some (Tagged { openness = Open; _ }) -> ()
     | Some (Record _ | Enum _ | Tagged { openness = Closed; _ }) | None ->
       Alcotest.fail "frame is not an open tagged sum");
    (match find_def "custom_name" defs with
     | Some (Enum { openness = Open; _ }) -> ()
     | Some (Record _ | Tagged _ | Enum { openness = Closed; _ }) | None ->
       Alcotest.fail "custom_name is not an open enum");
    (match find_def "role" defs with
     | Some (Enum { openness = Closed; _ }) -> ()
     | Some (Record _ | Tagged _ | Enum { openness = Open; _ }) | None ->
       Alcotest.fail "role is not a closed enum")

let type_field = {|<json adapter.ocaml="Atdgen_runtime.Json_adapter.Type_field">|}

(* (case, ATD text, a phrase of the reason) *)
let refusals =
  [ "payload without the type-field adapter", "type r = { x : int }\ntype t = [ A of r ]", "needs <json adapter.ocaml"
  ; "another adapter", {|type r = { x : int }
type t = [ A of r ] <json adapter.ocaml="My.Adapter">|}, "adapter My.Adapter"
  ; "another language's annotation", {|type t = { x <python name="y"> : int }|}, "<python name>"
  ; "an unknown json annotation", {|type t = { x : int } <json keep_nulls>|}, "<json keep_nulls>"
  ; "nullable", "type t = { x : int nullable }", "nullable"
  ; "a wire name that needs escaping", {|type t = { x <json name="x-y"> : int }|}, "wire name"
  ; "a payload that is not named", "type r = { x : int }\ntype t = [ A of r list ] " ^ type_field, "named record"
  ; "a payload that is not a record", "type e = [ A | B ]\ntype t = [ X of e ] " ^ type_field, "not a record"
  ; "a default field", "type t = { ~x : int }", "default field"
  ; "an abstract type that is not json", "type t = abstract", "record or a sum"
  ; "a parametric type", "type 'a t = { x : 'a }", "parametric"
  ; "a field that becomes a Swift keyword", "type t = { default : int }", "a Swift keyword"
  ; "a case that becomes a Swift keyword", "type t = [ Default | B ]", "a Swift keyword"
  ; "two fields that become one name", "type t = { run_id : int; run__id : int }", "both become runId"
  ; "two types that become one name", "type a_b = { x : int }\ntype a__b = { x : int }", "both become AB"
  ; "a type the generated Swift names", "type double = { x : int }", "already names"
  ; "an open case named unrecognized", "type t = [ A | Unrecognized ] <native open>", "<native open> adds"
  ]

let contains ~phrase text =
  let n = String.length phrase in
  let rec at i = i + n <= String.length text && (String.sub text i n = phrase || at (i + 1)) in
  at 0

let refusal_case (name, text, phrase) =
  Alcotest.test_case name `Quick (fun () ->
    match Native_ir.of_module (load_string text) with
    | Ok _ -> Alcotest.fail "taken; it must be refused"
    | Error message ->
      if not (contains ~phrase message)
      then Alcotest.failf "refused for another reason: %s" message)

let () =
  Alcotest.run "atd-native-gen"
    [ "wire", [ Alcotest.test_case "keeper_chat_wire.atd is taken" `Quick test_wire_is_taken ]
    ; "refused", List.map refusal_case refusals
    ]
