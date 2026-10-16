(* The codec the MSX routes encode refusals with and the terminal decodes
   with. *)
open Alcotest

let refusal = testable
  (fun fmt (r : Msx_wire.refusal) ->
    Format.fprintf fmt "{code=%s; message=%s}"
      (match r.code with Some c -> Msx_wire.code_to_wire c | None -> "-")
      (Option.value ~default:"-" r.message))
  ( = )

let test_every_code_round_trips () =
  List.iter (fun code ->
    check (option bool) ("wire name of " ^ Msx_wire.code_to_wire code) (Some true)
      (Option.map (fun parsed -> parsed = code) (Msx_wire.code_of_wire (Msx_wire.code_to_wire code)));
    check (result refusal string) "encode then decode"
      (Ok {Msx_wire.code = Some code; message = Some "why"})
      (Msx_wire.decode (Msx_wire.encode ~code "why")))
    Msx_wire.all_of_code;
  check (result refusal string) "a refusal without a code"
    (Ok {Msx_wire.code = None; message = Some "why"})
    (Msx_wire.decode (Msx_wire.encode "why"));
  check int "wire names are distinct" (List.length Msx_wire.all_of_code)
    (List.length (List.sort_uniq String.compare (List.map Msx_wire.code_to_wire Msx_wire.all_of_code)))

let test_decode_reads_fields_by_name () =
  let decoded = Msx_wire.decode (`Assoc ["added_later", `Int 1; "message", `String "m";
    "ok", `Bool false; "code", `String "activity_disabled"]) in
  check (result refusal string) "order and extra fields do not matter"
    (Ok {Msx_wire.code = Some Msx_wire.Activity_disabled; message = Some "m"}) decoded;
  check (result refusal string) "message is optional"
    (Ok {Msx_wire.code = Some Msx_wire.Outcome_unknown; message = None})
    (Msx_wire.decode (`Assoc ["ok", `Bool false; "code", `String "outcome_unknown"]))

let test_decode_refuses_what_it_cannot_name () =
  List.iter (fun (label, json) ->
    check bool label true (Result.is_error (Msx_wire.decode json)))
    ["not an object", `List [];
     "success body", `Assoc ["ok", `Bool true; "code", `String "activity_disabled"];
     "no ok", `Assoc ["code", `String "activity_disabled"];
     "ok is not a bool", `Assoc ["ok", `String "false"];
     "code this build does not name", `Assoc ["ok", `Bool false; "code", `String "other"];
     "code is not a string", `Assoc ["ok", `Bool false; "code", `Int 1];
     "message is not a string", `Assoc ["ok", `Bool false; "message", `Int 1];
     "repeated field", `Assoc ["ok", `Bool false; "ok", `Bool false]]

let () = run "MSX wire" ["refusal", [
  test_case "every code round-trips" `Quick test_every_code_round_trips;
  test_case "fields are read by name" `Quick test_decode_reads_fields_by_name;
  test_case "unnameable bodies are errors" `Quick test_decode_refuses_what_it_cannot_name]]
