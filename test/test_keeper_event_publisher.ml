open Alcotest

module Publisher = Masc.Keeper_event_publisher

let assoc_fields = function
  | `Assoc fields -> fields
  | json ->
    failf "expected object payload, got %s" (Yojson.Safe.to_string json)

let field name fields =
  match List.assoc_opt name fields with
  | Some value -> value
  | None -> failf "missing field %S" name

let check_json label expected actual =
  check string label (Yojson.Safe.to_string expected) (Yojson.Safe.to_string actual)

let count_field name fields =
  List.fold_left
    (fun count (field_name, _) ->
      if String.equal field_name name then count + 1 else count)
    0
    fields

let test_object_payload_keeps_fields_and_adds_event_name () =
  let payload =
    `Assoc [ ("runtime_id", `String "r1"); ("attempt", `Int 2) ]
  in
  let fields =
    Publisher.telemetry_event_payload
      ~event_name:"cascade_resolution"
      ~payload
    |> assoc_fields
  in
  check_json "event_name" (`String "cascade_resolution")
    (field "event_name" fields);
  check_json "runtime_id" (`String "r1") (field "runtime_id" fields);
  check_json "attempt" (`Int 2) (field "attempt" fields)

let test_object_payload_replaces_existing_event_name () =
  let payload =
    `Assoc [ ("event_name", `String "stale"); ("detail", `String "ok") ]
  in
  let fields =
    Publisher.telemetry_event_payload
      ~event_name:"runtime_execution_built"
      ~payload
    |> assoc_fields
  in
  check int "event_name appears once" 1 (count_field "event_name" fields);
  check_json "event_name" (`String "runtime_execution_built")
    (field "event_name" fields);
  check_json "detail" (`String "ok") (field "detail" fields)

let test_non_object_payload_wraps_value () =
  let payload = `List [ `String "a"; `String "b" ] in
  let fields =
    Publisher.telemetry_event_payload
      ~event_name:"tool_dispatch"
      ~payload
    |> assoc_fields
  in
  check_json "event_name" (`String "tool_dispatch") (field "event_name" fields);
  check_json "payload" payload (field "payload" fields)

let () =
  run "keeper_event_publisher"
    [
      ( "telemetry payload",
        [
          test_case "object payload keeps fields and adds event_name" `Quick
            test_object_payload_keeps_fields_and_adds_event_name;
          test_case "object payload replaces existing event_name" `Quick
            test_object_payload_replaces_existing_event_name;
          test_case "non-object payload wraps value" `Quick
            test_non_object_payload_wraps_value;
        ] );
    ]
