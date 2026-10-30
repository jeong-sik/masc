(* Standalone SDK microbenchmark. No provider, Keeper or MASC runtime is started. *)
open Agent_core

exception Invalid_measurement of string

let utf8_marker = "서울 · 東京 · 🧪"

let rich_input_schema index : Yojson.Safe.t =
  `Assoc
    [ "type", `String "object"
    ; "title", `String (Printf.sprintf "Workspace search %06d" index)
    ; "additionalProperties", `Bool false
    ; ( "properties"
      , `Assoc
          [ ( "query"
            , `Assoc
                [ "type", `String "string"
                ; "description", `String ("Search text: " ^ utf8_marker ^ "\nquoted: \"term\"")
                ; "minLength", `Int 1
                ; "default", `String utf8_marker
                ] )
          ; ( "mode"
            , `Assoc
                [ "type", `String "string"
                ; "enum", `List [ `String "preview"; `String "full" ]
                ; "default", `String "preview"
                ] )
          ; ( "window"
            , `Assoc
                [ "type", `String "object"
                ; "additionalProperties", `Bool false
                ; ( "properties"
                  , `Assoc
                      [ ( "offset"
                        , `Assoc
                            [ "type", `String "integer"
                            ; "minimum", `Int 0
                            ; "default", `Int 0
                            ] )
                      ; ( "length"
                        , `Assoc
                            [ "type", `String "integer"
                            ; "minimum", `Int 1
                            ; "maximum", `Int 65536
                            ; "default", `Int 4096
                            ] )
                      ] )
                ; "required", `List [ `String "offset"; `String "length" ]
                ] )
          ; ( "labels"
            , `Assoc
                [ "type", `String "array"
                ; "description", `String "Optional labels and escaped paths, e.g. C:\\workspace"
                ; "items", `Assoc [ "type", `String "string" ]
                ; "uniqueItems", `Bool true
                ] )
          ] )
    ; "required", `List [ `String "query"; `String "mode"; `String "window" ]
    ]

let make_schemas ~start count =
  Array.init count (fun offset ->
    let index = start + offset in
    match
      Types.tool_schema_of_input_schema
        ~strict:true
        ~name:(Printf.sprintf "workspace_search_%06d" index)
        ~description:("Search a workspace and return a bounded window. " ^ utf8_marker)
        ~input_schema:(rich_input_schema index)
        ()
    with
    | Ok schema -> schema
    | Error detail -> raise (Invalid_measurement ("fixture schema: " ^ detail)))

let direct_serialization_bytes schema =
  String.length (Yojson.Safe.to_string (Tool.wire_json_of_schema schema))

let checked_add left right =
  if right < 0 || left > max_int - right then
    raise (Invalid_measurement "byte checksum exceeds the OCaml integer range");
  left + right

let checked_product label left right =
  if left > max_int / right then
    raise (Invalid_measurement (label ^ " exceeds the OCaml integer range"));
  left * right

let checked_sum values = Array.fold_left checked_add 0 values

(* Integer checksums keep the measured inner loop free of Int64 allocation.
   Expected sums are range-checked separately before accepting any result. *)
let repeat_sum ~repetitions bytes schemas =
  let checksum = ref 0 in
  for _repetition = 1 to repetitions do
    for index = 0 to Array.length schemas - 1 do
      checksum := !checksum + bytes schemas.(index)
    done
  done;
  Sys.opaque_identity !checksum

type timing =
  { elapsed_ns : float
  ; allocated_bytes : float
  }

let timed work =
  let allocated_before = Gc.allocated_bytes () in
  let counter = Mtime_clock.counter () in
  let result = work () in
  let elapsed_ns = Mtime.Span.to_float_ns (Mtime_clock.count counter) in
  let allocated_bytes = Gc.allocated_bytes () -. allocated_before in
  result, { elapsed_ns; allocated_bytes }

let emit fields = print_endline (Yojson.Safe.to_string (`Assoc fields))

let report ~phase ~input_count ~repetitions ~checksum timing =
  emit
    [ "phase", `String phase
    ; "input_count", `Int input_count
    ; "repetitions", `Int repetitions
    ; "operations", `Int (checked_product "operation count" input_count repetitions)
    ; "elapsed_monotonic_ns", `Float timing.elapsed_ns
    ; "allocated_bytes", `Float timing.allocated_bytes
    ; "byte_checksum", (match checksum with None -> `Null | Some value -> `Int value)
    ]

let require_sum phase expected actual =
  if expected <> actual then
    raise
      (Invalid_measurement
         (Printf.sprintf "%s: expected byte checksum %d, received %d" phase expected actual))

let prepare ~phase ~start count =
  let schemas, timing = timed (fun () -> make_schemas ~start count) in
  report ~phase ~input_count:count ~repetitions:1 ~checksum:None timing;
  schemas

let measure_sum ~phase ~repetitions schemas bytes =
  let checksum, timing = timed (fun () -> repeat_sum ~repetitions bytes schemas) in
  report ~phase ~input_count:(Array.length schemas) ~repetitions ~checksum:(Some checksum) timing;
  checksum

let run ~schema_count ~repetitions ~cold_batches =
  let cold_count = checked_product "cold input count" schema_count cold_batches in
  if cold_count > Sys.max_array_length || schema_count > Sys.max_array_length then
    raise (Invalid_measurement "schema count exceeds Sys.max_array_length");
  ignore (checked_add schema_count cold_count);
  ignore (checked_product "hot operation count" schema_count repetitions);
  emit
    [ "benchmark", `String "agent_core_schema_wire_bytes"
    ; "scope", `String "single-process single-domain SDK microbenchmark"
    ; "reference", `String "same-build direct serialization; not a source baseline"
    ; "ocaml_version", `String Sys.ocaml_version
    ; "word_size", `Int Sys.word_size
    ; "schema_count", `Int schema_count
    ; "hot_repetitions", `Int repetitions
    ; "cold_batches", `Int cold_batches
    ; "cold_distinct_input_count_per_path", `Int cold_count
    ; "utf8_fixture_marker", `String utf8_marker
    ; "utf8_fixture_marker_bytes", `Int (String.length utf8_marker)
    ; ( "limits"
      , `String
          "Elapsed time and allocation include harness overhead and GC. Fixed phase order and growing weak-cache population affect cold rows. No CPU-causality, installed-runtime, fleet or 0.1ms-goal claim." )
    ];
  let hot = prepare ~phase:"hot_prepare_schemas" ~start:0 schema_count in
  let (), json_timing =
    timed (fun () -> Array.iter (fun schema -> ignore (Tool.wire_json_of_schema schema)) hot)
  in
  report ~phase:"hot_prime_wire_json" ~input_count:schema_count ~repetitions:1 ~checksum:None json_timing;
  let expected_lengths, reference_timing =
    timed (fun () -> Array.map direct_serialization_bytes hot)
  in
  let expected_hot_once = checked_sum expected_lengths in
  report ~phase:"hot_prepare_reference_lengths" ~input_count:schema_count ~repetitions:1
    ~checksum:(Some expected_hot_once) reference_timing;
  let actual_lengths, prime_timing =
    timed (fun () -> Array.map Tool.wire_bytes_of_schema hot)
  in
  Array.iteri
    (fun index expected -> require_sum "hot per-schema UTF-8 byte equivalence" expected actual_lengths.(index))
    expected_lengths;
  report ~phase:"hot_prime_byte_count" ~input_count:schema_count ~repetitions:1
    ~checksum:(Some (checked_sum actual_lengths)) prime_timing;
  let expected_hot = checked_product "hot byte checksum" expected_hot_once repetitions in
  let hot_memo = measure_sum ~phase:"hot_byte_count" ~repetitions hot Tool.wire_bytes_of_schema in
  require_sum "hot byte count" expected_hot hot_memo;
  let hot_reference =
    measure_sum ~phase:"hot_same_build_direct_serialization" ~repetitions hot direct_serialization_bytes
  in
  require_sum "hot direct serialization" expected_hot hot_reference;
  (* Keep all inputs alive. Each cold path receives newly constructed physical
     schemas, with equal field values, and calls its operation once per schema. *)
  let cold_memo = prepare ~phase:"cold_prepare_byte_count_schemas" ~start:schema_count cold_count in
  let cold_memo_sum =
    measure_sum ~phase:"cold_distinct_byte_count" ~repetitions:1 cold_memo Tool.wire_bytes_of_schema
  in
  let cold_reference =
    prepare ~phase:"cold_prepare_reference_schemas" ~start:schema_count cold_count
  in
  let cold_reference_sum =
    measure_sum ~phase:"cold_distinct_same_build_direct_serialization" ~repetitions:1
      cold_reference direct_serialization_bytes
  in
  let expected_cold, verification_timing =
    timed (fun () ->
      let sum = ref 0 in
      Array.iteri
        (fun index schema ->
          let reference_schema = cold_reference.(index) in
          if schema == reference_schema then
            raise (Invalid_measurement "cold paths share a physical schema");
          if Tool.wire_json_of_schema schema <> Tool.wire_json_of_schema reference_schema then
            raise (Invalid_measurement "cold paths have different wire definitions");
          let expected = direct_serialization_bytes schema in
          require_sum "cold memo per-schema UTF-8 byte equivalence" expected (Tool.wire_bytes_of_schema schema);
          require_sum "cold reference per-schema UTF-8 byte equivalence" expected (Tool.wire_bytes_of_schema reference_schema);
          sum := checked_add !sum expected)
        cold_memo;
      !sum)
  in
  require_sum "cold byte count" expected_cold cold_memo_sum;
  require_sum "cold direct serialization" expected_cold cold_reference_sum;
  report ~phase:"cold_verify_byte_equivalence" ~input_count:cold_count ~repetitions:1
    ~checksum:(Some expected_cold) verification_timing;
  (* The final use also keeps hot keys strongly reachable across the cold rows. *)
  require_sum "retained hot surface" expected_hot_once (repeat_sum ~repetitions:1 Tool.wire_bytes_of_schema hot);
  emit
    [ "integrity", `String "PASS"
    ; "per_schema_utf8_byte_comparisons", `Int (checked_add schema_count (checked_product "comparison count" cold_count 2))
    ; "hot_byte_checksum", `Int expected_hot
    ; "cold_byte_checksum_per_path", `Int expected_cold
    ; "performance_threshold", `Null
    ]

let () =
  let schema_count = ref 16 in
  let repetitions = ref 1000 in
  let cold_batches = ref 4 in
  let positive name target value =
    if value <= 0 then raise (Arg.Bad (name ^ " must be positive"));
    target := value
  in
  Arg.parse
    [ "--schemas", Arg.Int (positive "--schemas" schema_count), "N Physical schemas in the shared hot surface (default 16)"
    ; "--repetitions", Arg.Int (positive "--repetitions" repetitions), "N Hot traversals over the same schemas (default 1000)"
    ; "--cold-batches", Arg.Int (positive "--cold-batches" cold_batches), "N Cold input count multiplier; each input is used once (default 4)"
    ]
    (fun value -> raise (Arg.Bad ("unexpected argument: " ^ value)))
    "schema_wire_bytes_bench [--schemas N] [--repetitions N] [--cold-batches N]";
  match run ~schema_count:!schema_count ~repetitions:!repetitions ~cold_batches:!cold_batches with
  | () -> ()
  | exception Invalid_measurement detail ->
    prerr_endline (Yojson.Safe.to_string (`Assoc [ "integrity", `String "FAIL"; "detail", `String detail ]));
    exit 2
