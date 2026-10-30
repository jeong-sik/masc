(* UNEXECUTED private carrier probe. This is not a typed project test or timing
   driver. Every compared byte string and SHA is retained in the future report.
   Carrier edge values do not claim Agent_core constructor admissibility. *)
open Fixture_carrier

exception Probe_failure of string
exception Injected_conversion of int
exception Injected_sink of int

let require condition detail = if not condition then raise (Probe_failure detail)

let schema ?strict ?input_schema name =
  `Assoc
    ([ "name", `String name; "description", `String ""; "parameters", `List [] ]
     @ (match strict with None -> [] | Some value -> [ "strict", `Bool value ])
     @ (match input_schema with None -> [] | Some value -> [ "input_schema", value ]))
;;

let builtin schema_json = { source = Builtin; schema_json }

let attached ?(provider_id = "provider-a") ?(endpoint = "https://fixture.invalid/mcp")
    ?(remote_name = "inspect") schema_json =
  { source = Attached { provider_id; endpoint; remote_name }; schema_json }
;;

(* Deliberately independent of the oracle source projection and in a different
   object-field order. Sorting must produce the same original canonical bytes. *)
let entry_json ({ source; schema_json } : entry) =
  let identity =
    match source with
    | Builtin -> `Assoc [ "kind", `String "builtin" ]
    | Attached { provider_id; endpoint; remote_name } ->
      `Assoc
        [ "remote_name", `String remote_name; "endpoint", `String endpoint
        ; "provider_id", `String provider_id; "kind", `String "attached"
        ]
  in
  `Assoc [ "schema", schema_json; "source", identity ]
;;

let candidate_bytes entries =
  let buffer = Buffer.create 256 in
  Canonical_list_digest.iter_canonical_chunks ~to_json:entry_json entries
    (Buffer.add_string buffer);
  Buffer.contents buffer
;;

let hex text =
  let buffer = Buffer.create (2 * String.length text) in
  String.iter (fun value -> Buffer.add_string buffer (Printf.sprintf "%02x" (Char.code value))) text;
  Buffer.contents buffer
;;

let run () =
  let records = ref [] in
  let check name entries =
    let old_bytes = Old_oracle_carrier.canonical_bytes entries in
    let new_bytes = candidate_bytes entries in
    require (String.equal old_bytes new_bytes) (name ^ ": canonical byte mismatch");
    let old_digest = Old_oracle_carrier.digest entries in
    let new_digest = Canonical_list_digest.digest ~to_json:entry_json entries in
    require (Digestif.SHA256.equal old_digest new_digest) (name ^ ": digest mismatch");
    require (Digestif.SHA256.equal old_digest (Digestif.SHA256.digest_string old_bytes))
      (name ^ ": oracle byte/hash mismatch");
    records :=
      `Assoc
        [ "case", `String name; "byte_length", `Int (String.length old_bytes)
        ; "oracle_bytes_hex", `String (hex old_bytes)
        ; "candidate_bytes_hex", `String (hex new_bytes)
        ; "oracle_sha256", `String (Digestif.SHA256.to_hex old_digest)
        ; "candidate_sha256", `String (Digestif.SHA256.to_hex new_digest)
        ]
      :: !records;
    old_bytes
  in
  let minimal = builtin (schema "noop") in
  let attached_minimal =
    attached (schema ~strict:true
      ~input_schema:(`Assoc [ "type", `String "object"; "properties", `Assoc []
                           ; "additionalProperties", `Bool false ]) "remote.inspect")
  in
  let nested =
    `Assoc
      [ "type", `String "object"
      ; "$defs", `Assoc [ "item", `Assoc [ "type", `String "string"; "enum", `List [ `String "a"; `String "b" ] ] ]
      ; "properties", `Assoc [ "payload", `Assoc
          [ "anyOf", `List [ `Assoc [ "$ref", `String "#/$defs/item" ]; `Assoc [ "type", `String "null" ] ]
          ; "default", `String "a"; "description", `String "nested" ] ]
      ; "required", `List [ `String "payload" ]; "additionalProperties", `Bool false
      ]
  in
  let duplicate_a = builtin (`Assoc [ "same", `Int 1; "same", `Int 2; "z", `Null ]) in
  let duplicate_b = builtin (`Assoc [ "same", `Int 2; "same", `Int 1; "z", `Null ]) in
  let cases =
    [ "empty", []
    ; "singleton-builtin", [ minimal ]
    ; "attached-full-identity", [ attached_minimal ]
    ; "mixed-ordered", [ minimal; attached_minimal ]
    ; "nested-full-schema-carrier", [ attached (schema ~input_schema:nested "nested") ]
    ; "escaping", [ builtin (schema "quote\" slash\\ controls\000\008\009\010\012\013 / 한글 é") ]
    ; "byte-string-carrier", [ builtin (`Assoc [ "raw", `String "\255\128" ]) ]
    ; "numeric-carrier", [ builtin (`Assoc
        [ "bounds", `List [ `Int min_int; `Int max_int; `Intlit "123456789012345678901234567890" ]
        ; "floats", `List [ `Float (-0.); `Float 1.; `Float 1e-200; `Float 1e200 ] ]) ]
    ; "duplicate-key-stability-a-carrier", [ duplicate_a ]
    ; "duplicate-key-stability-b-carrier", [ duplicate_b ]
    ; "raw-intlit-edge-carrier", [ builtin (`Assoc [ "a", `Intlit "01"; "b", `Intlit "not-json" ]) ]
    ; "schema-null-carrier", [ builtin `Null ]
    ; "schema-array-carrier", [ builtin (`List [ `String "x"; `Bool false; `Null ]) ]
    ; "unknown-schema-field-carrier", [ builtin (`Assoc [ "name", `String "noop"; "future_field", nested ]) ]
    ; "repeated-entries", [ minimal; minimal; attached_minimal; minimal ]
    ; "many-rows", List.init 17 (fun index -> builtin (schema (string_of_int index)))
    ; "large-entry-carrier", [ attached (`Assoc [ "name", `String "large"; "description", `String (String.make 4096 'x'); "schema", nested ]) ]
    ]
  in
  List.iter (fun (name, entries) -> ignore (check name entries)) cases;
  (* The active, later Yojson3.0.0 write_float binding rejects nonfinite values.
     Keep all three as explicit matched-error cases, including failures after
     a valid row has already been fed. Never treat an exception as successful
     bytes, and never hide a candidate-only failure or changed message/class. *)
  let serializer_errors = ref [] in
  List.iter
    (fun (name, value, expected_message) ->
       let invalid = builtin (`Assoc [ "value", `Float value ]) in
       let entries = [ minimal; invalid; attached_minimal ] in
       let reject_serialization label operation =
         match operation () with
         | _ -> raise (Probe_failure (name ^ ": " ^ label ^ " unexpectedly returned"))
         | exception (Yojson.Json_error message) -> message
       in
       let old_bytes_message = reject_serialization "old bytes"
           (fun () -> Old_oracle_carrier.canonical_bytes entries) in
       let new_bytes_message = reject_serialization "candidate bytes"
           (fun () -> candidate_bytes entries) in
       let old_digest_message = reject_serialization "old digest"
           (fun () -> Old_oracle_carrier.digest entries) in
       let new_digest_message = reject_serialization "candidate digest"
           (fun () -> Canonical_list_digest.digest ~to_json:entry_json entries) in
       require
         (List.for_all (String.equal expected_message)
            [ old_bytes_message; new_bytes_message; old_digest_message; new_digest_message ])
         (name ^ ": old/new serializer error class/message differs");
       let failure message =
         `Assoc [ "returned", `Bool false; "exception_class", `String "Yojson.Json_error"
                ; "message", `String message ]
       in
       serializer_errors :=
         `Assoc
           [ "case", `String name; "position", `String "after-valid-prefix"
           ; "old_bytes", failure old_bytes_message; "candidate_bytes", failure new_bytes_message
           ; "old_digest", failure old_digest_message; "candidate_digest", failure new_digest_message
           ; "matched_class_and_message", `Bool true
           ; "no_bytes_or_digest_returned", `Bool true
           ; "physical_exception_identity_compared", `Bool false
           ; "identity_limit", `String "Separate serializer calls construct independent exceptions; injected conversion faults below still require original object identity."
           ]
         :: !serializer_errors)
    [ "nan", (0. /. 0.), "NaN value not allowed in standard JSON"
    ; "positive-infinity", (1. /. 0.), "Infinity value not allowed in standard JSON"
    ; "negative-infinity", (-1. /. 0.), "-Infinity value not allowed in standard JSON"
    ];
  (* Hand-authored ASCII byte goldens, hashed as fixture data during preparation.
     They do not come from either serializer implementation. *)
  let goldens = Yojson.Safe.from_file "goldens.json" |> Yojson.Safe.Util.to_list in
  List.iter
    (fun row ->
       let get key = Yojson.Safe.Util.member key row |> Yojson.Safe.Util.to_string in
       let name = get "case" in
       let entries = List.assoc name cases in
       let actual = Old_oracle_carrier.canonical_bytes entries in
       require (String.equal actual (get "canonical_bytes")) (name ^ ": handwritten golden bytes differ");
       require (String.equal (Digestif.SHA256.to_hex (Old_oracle_carrier.digest entries)) (get "sha256"))
         (name ^ ": handwritten golden SHA differs"))
    goldens;
  let same name left right =
    require (String.equal (check (name ^ "-a") left) (check (name ^ "-b") right))
      (name ^ ": field permutation changed canonical bytes")
  in
  let different name left right =
    let a = check (name ^ "-a") left in
    let b = check (name ^ "-b") right in
    require (not (String.equal a b)) (name ^ ": material input change lost");
    require (not (Digestif.SHA256.equal (Digestif.SHA256.digest_string a) (Digestif.SHA256.digest_string b)))
      (name ^ ": observed digest mutation lost")
  in
  same "recursive-field-permutation"
    [ builtin (`Assoc [ "z", `Assoc [ "b", `Int 2; "a", `Int 1 ]; "a", `List [ `Int 3; `Int 4 ] ]) ]
    [ builtin (`Assoc [ "a", `List [ `Int 3; `Int 4 ]; "z", `Assoc [ "a", `Int 1; "b", `Int 2 ] ]) ];
  different "surface-order" [ minimal; attached_minimal ] [ attached_minimal; minimal ];
  different "duplicates-not-deduplicated" [ minimal ] [ minimal; minimal ];
  different "array-order" [ builtin (`List [ `Int 1; `Int 2 ]) ] [ builtin (`List [ `Int 2; `Int 1 ]) ];
  different "duplicate-object-field-order" [ duplicate_a ] [ duplicate_b ];
  different "builtin-versus-attached" [ minimal ] [ attached minimal.schema_json ];
  different "provider-id" [ attached minimal.schema_json ] [ attached ~provider_id:"provider-b" minimal.schema_json ];
  different "endpoint" [ attached minimal.schema_json ] [ attached ~endpoint:"https://other.invalid/mcp" minimal.schema_json ];
  different "remote-name" [ attached minimal.schema_json ] [ attached ~remote_name:"other" minimal.schema_json ];
  different "schema-name" [ minimal ] [ builtin (schema "changed") ];
  different "schema-description" [ minimal ] [ builtin (`Assoc [ "name", `String "noop"; "description", `String "changed"; "parameters", `List [] ]) ];
  different "schema-parameters" [ minimal ] [ builtin (`Assoc [ "name", `String "noop"; "description", `String ""; "parameters", `List [ `Assoc [ "name", `String "p"; "description", `String ""; "param_type", `String "string"; "required", `Bool true ] ] ]) ];
  different "strict-absent-false" [ minimal ] [ builtin (schema ~strict:false "noop") ];
  different "strict-false-true" [ builtin (schema ~strict:false "noop") ] [ builtin (schema ~strict:true "noop") ];
  different "input-schema-full-constraints" [ builtin (schema ~input_schema:nested "noop") ]
    [ builtin (schema ~input_schema:(`Assoc [ "type", `String "object" ]) "noop") ];
  let faults = ref [] in
  List.iter
    (fun failed_index ->
       let primary = Injected_conversion failed_index in
       let observe digest =
         let visited = ref [] in
         let to_json index =
           visited := index :: !visited;
           if index = failed_index then raise primary;
           `Assoc [ "index", `Int index ]
         in
         match digest ~to_json [ 0; 1; 2 ] with
         | _ -> raise (Probe_failure "conversion failure returned a digest")
         | exception (Injected_conversion _ as raised) ->
           require (raised == primary) "original conversion exception identity was replaced";
           List.rev !visited
       in
       let old_visited = observe Old_oracle_carrier.digest_projected in
       let new_visited = observe Canonical_list_digest.digest in
       require (old_visited = new_visited) "conversion failure traversal differs";
       faults := `Assoc [ "kind", `String "old-new-conversion-failure"; "index", `Int failed_index
                         ; "no_digest_returned", `Bool true ] :: !faults)
    [ 0; 1; 2 ];
  List.iter
    (fun failed_chunk ->
       let primary = Injected_sink failed_chunk in
       let chunks = ref 0 in
       let emit _ = incr chunks; if !chunks = failed_chunk then raise primary in
       (match Canonical_list_digest.iter_canonical_chunks ~to_json:entry_json [ minimal; attached_minimal ] emit with
        | () -> raise (Probe_failure "sink failure was swallowed")
        | exception (Injected_sink _ as raised) -> require (raised == primary) "sink exception replaced");
       require (!chunks = failed_chunk) "sink failure retried emission";
       faults := `Assoc [ "kind", `String "private-iterator-sink-failure"; "chunk", `Int failed_chunk
                         ; "production-error-equivalence", `Bool false ] :: !faults)
    [ 1; 2; 3 ];
  require (List.length !records = 47) "successful byte/digest population incomplete";
  require (List.length !serializer_errors = 3) "expected serializer-error population incomplete";
  require (List.length goldens = 3 && List.length !faults = 6) "golden/injected fault population incomplete";
  `Assoc
    [ "schema", `String "masc.private-tool-surface-digest-correctness.v2"
    ; "status", `String "PRIVATE_CARRIER_CORRECTNESS_ONLY_NOT_TYPED_PROJECT_OR_PERFORMANCE"
    ; "byte_and_digest_cases", `List (List.rev !records)
    ; "successful_byte_and_digest_row_count", `Int (List.length !records)
    ; "expected_serializer_errors", `List (List.rev !serializer_errors)
    ; "expected_serializer_error_case_count", `Int (List.length !serializer_errors)
    ; "golden_count", `Int (List.length goldens); "fault_cases", `List (List.rev !faults)
    ; "actual_agent_core_loaded", `Bool false; "timing_benchmark", `Bool false
    ]
  |> Yojson.Safe.to_string
  |> print_endline
;;
