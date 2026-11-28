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

let test_wire_is_taken () =
  match Native_ir.of_module (wire ()) with
  | Error message -> Alcotest.fail message
  | Ok defs ->
    (match find_def "frame" defs with
     | Some (Tagged { cases; openness = Open; _ }) ->
       Alcotest.(check int) "frame kinds" 10 (List.length cases)
     | Some (Record _ | Enum _ | Tagged { openness = Closed; _ }) | None ->
       Alcotest.fail "frame is not an open tagged sum");
    (match find_def "custom_name" defs with
     | Some (Enum { cases; openness = Open; _ }) ->
       Alcotest.(check int) "custom names" 30 (List.length cases)
     | Some (Record _ | Tagged _ | Enum { openness = Closed; _ }) | None ->
       Alcotest.fail "custom_name is not an open enum");
    (match find_def "role" defs with
     | Some (Enum { openness = Closed; _ }) -> ()
     | Some (Record _ | Tagged _ | Enum { openness = Open; _ }) | None ->
       Alcotest.fail "role is not a closed enum");
    Alcotest.(check bool) "json alias is not a type of its own" true (find_def "json" defs = None)

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
