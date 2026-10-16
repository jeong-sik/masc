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

(* One decoder reads a tick for the route and the worker. It bounds nothing:
   the route clamps what the terminal sends and the worker refuses what the
   lane rejects. *)
let test_tick_decoding () =
  let revision = String.make 64 'a' in
  let reference = `Assoc ["revision", `String revision; "width", `Int 256; "height", `Int 192] in
  let decoded json = Result.get_ok (Msx_wire.decode_tick json) in
  check bool "an empty tick names nothing" true
    (decoded (`Assoc []) = {Msx_wire.frames = None; pixel_response = Msx_wire.Full_frame});
  check bool "a count is passed on unbounded, in either direction" true
    ((decoded (`Assoc ["frames", `Int 100000])).Msx_wire.frames = Some 100000
     && (decoded (`Assoc ["frames", `Int (-4)])).Msx_wire.frames = Some (-4));
  check bool "retained without a reference" true
    ((decoded (`Assoc ["pixel_response", `String "retained"])).Msx_wire.pixel_response
     = Msx_wire.Retained_pixels None);
  check bool "retained with the client's pixels" true
    ((decoded (`Assoc ["frames", `Int 3; "pixel_response", `String "retained";
                       "known_pixels", reference])).Msx_wire.pixel_response
     = Msx_wire.Retained_pixels (Some {Msx_wire.revision; width = 256; height = 192}));
  List.iter (fun (label, json) ->
    check bool label true (Result.is_error (Msx_wire.decode_tick json)))
    ["not an object", `List [];
     "an unknown field", `Assoc ["frame", `Int 3];
     "a repeated field", `Assoc ["frames", `Int 3; "frames", `Int 4];
     "frames that is not an integer", `Assoc ["frames", `String "3"];
     "frames that is a float", `Assoc ["frames", `Float 1.5];
     "pixel_response that is not retained", `Assoc ["pixel_response", `String "full"];
     "known pixels without retained", `Assoc ["known_pixels", reference];
     "a reference with a short revision", `Assoc ["pixel_response", `String "retained";
       "known_pixels", `Assoc ["revision", `String "abc"; "width", `Int 1; "height", `Int 1]];
     "a reference with an upper-case revision", `Assoc ["pixel_response", `String "retained";
       "known_pixels", `Assoc ["revision", `String (String.make 64 'A'); "width", `Int 1; "height", `Int 1]];
     "a reference with no height", `Assoc ["pixel_response", `String "retained";
       "known_pixels", `Assoc ["revision", `String revision; "width", `Int 1]];
     "a reference with a zero width", `Assoc ["pixel_response", `String "retained";
       "known_pixels", `Assoc ["revision", `String revision; "width", `Int 0; "height", `Int 1]]]

let () = run "MSX wire" ["refusal", [
  test_case "every code round-trips" `Quick test_every_code_round_trips;
  test_case "fields are read by name" `Quick test_decode_reads_fields_by_name;
  test_case "unnameable bodies are errors" `Quick test_decode_refuses_what_it_cannot_name];
  "tick", [test_case "one decoder for the route and the worker" `Quick test_tick_decoding]]
