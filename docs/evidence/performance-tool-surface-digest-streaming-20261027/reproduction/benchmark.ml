open Fixture_carrier

let require condition text = if not condition then failwith text
let project ({ source; schema_json } : entry) =
  `Assoc [ "source", Old_oracle_carrier.source_to_json source; "schema", schema_json ]
let old_digest rows = Old_oracle_carrier.digest_projected ~to_json:project rows
let new_digest rows = Canonical_list_digest.digest ~to_json:project rows
let emit value = print_endline (Yojson.Safe.to_string value)
let str x = `String x
let num x = `Float x
let int x = `Int x
let i64 x = str (Int64.to_string x)
let gc (s : Gc.stat) = `Assoc
  [ "minor_words", num s.minor_words; "major_words", num s.major_words
  ; "promoted_words", num s.promoted_words; "minor_collections", int s.minor_collections
  ; "major_collections", int s.major_collections; "compactions", int s.compactions
  ; "heap_words", int s.heap_words; "live_words", int s.live_words ]
let controls () = let c = Gc.get () in `Assoc
  [ "minor_heap_size", int c.minor_heap_size; "major_heap_increment", int c.major_heap_increment
  ; "space_overhead", int c.space_overhead; "max_overhead", int c.max_overhead
  ; "allocation_policy", int c.allocation_policy ]
let schema description = `Assoc
  [ "name", str "fixture.inspect"; "description", str description; "parameters", `List []
  ; "input_schema", `Assoc [ "type", str "object"; "additionalProperties", `Bool false
      ; "properties", `Assoc [ "payload", `Assoc [ "type", str "string"; "maxLength", int 4096 ] ] ] ]
let entry index description =
  { source = (if index mod 2 = 0 then Builtin else Attached
      { provider_id = "fixture-provider"; endpoint = "https://fixture.invalid/mcp"; remote_name = "inspect" })
  ; schema_json = schema description }
let tiny count = List.init count (fun index -> entry index "fixture")
let large count bytes = List.init count (fun index -> entry index (String.make bytes 'x'))
let mixed position = List.init 16 (fun index -> entry index (if index = position then String.make 16384 'x' else "fixture"))
let strata () =
  [ "empty", [], 5000; "singleton-builtin", tiny 1, 2000
  ; "singleton-attached", [ { (entry 1 "fixture") with source = Attached
      { provider_id = "fixture-provider"; endpoint = "https://fixture.invalid/mcp"; remote_name = "inspect" } } ], 2000
  ; "tiny-2", tiny 2, 1000; "tiny-16", tiny 16, 128; "tiny-128", tiny 128, 16
  ; "tiny-512", tiny 512, 4; "description16KiB-1", large 1 16384, 128
  ; "description1KiB-16", large 16 1024, 32; "description1KiB-128", large 128 1024, 4
  ; "description16KiB-128", large 128 16384, 1
  ; "mixed-large-first", mixed 0, 16; "mixed-large-middle", mixed 8, 16
  ; "mixed-large-last", mixed 15, 16 ]
let run () =
  emit (`Assoc [ "kind", str "metadata"; "status", str "WARM_PRIVATE_CARRIER_ONLY"
    ; "ocaml_version", str Sys.ocaml_version; "word_bits", int Sys.word_size
    ; "backend", str (match Sys.backend_type with Bytecode -> "Bytecode" | Native -> "Native" | Other s -> s)
    ; "os_type", str Sys.os_type; "gc_controls", controls ()
    ; "clock", str "Mtime_clock.counter/count"; "process_cpu", str "Sys.time"
    ; "allocation", str "Gc.allocated_bytes delta; caller-domain and measurement overhead included"
    ; "full_major_before_each_phase", `Bool true; "warmup_per_role_per_stratum", int 3
    ; "abba_cycles_per_stratum", int 4; "cold_or_peak_RSS_measured", `Bool false
    ; "actual_Agent_core_loaded", `Bool false; "fixture_projection_shared_by_both_roles", `Bool true ]);
  let rows_emitted = ref 0 in
  List.iter (fun (name, rows, iterations) ->
    let old_bytes = Old_oracle_carrier.canonical_bytes rows in
    let expected = old_digest rows in
    require (Digestif.SHA256.equal expected (new_digest rows)) (name ^ ": preflight SHA mismatch");
    let candidate_buffer = Buffer.create 256 in
    Canonical_list_digest.iter_canonical_chunks ~to_json:project rows (Buffer.add_string candidate_buffer);
    require (String.equal old_bytes (Buffer.contents candidate_buffer)) (name ^ ": preflight byte mismatch");
    emit (`Assoc [ "kind", str "stratum"; "name", str name; "entries", int (List.length rows)
      ; "iterations_per_phase", int iterations; "canonical_bytes", int (String.length old_bytes)
      ; "expected_sha256", str (Digestif.SHA256.to_hex expected) ]);
    List.iter (fun digest -> for _ = 1 to 3 do ignore (Sys.opaque_identity (digest rows)) done)
      [ old_digest; new_digest ];
    for cycle = 1 to 4 do
      List.iteri (fun position (role, digest) ->
        let last = ref expected in
        Gc.full_major ();
        let gc_before = Gc.quick_stat () in
        let allocated_before = Gc.allocated_bytes () in
        let cpu_before = Sys.time () in
        let counter = Mtime_clock.counter () in
        for _ = 1 to iterations do last := Sys.opaque_identity (digest rows) done;
        let elapsed_ns = Mtime_clock.count counter |> Mtime.Span.to_uint64_ns in
        let cpu_after = Sys.time () in
        let allocated_after = Gc.allocated_bytes () in
        let gc_after = Gc.quick_stat () in
        require (Digestif.SHA256.equal expected !last) (name ^ ": timed final SHA mismatch");
        incr rows_emitted;
        emit (`Assoc [ "kind", str "phase"; "stratum", str name; "cycle", int cycle
          ; "position", int (position + 1); "role", str role; "iterations", int iterations
          ; "elapsed_ns", i64 elapsed_ns; "cpu_before_s", num cpu_before; "cpu_after_s", num cpu_after
          ; "allocated_before_B", num allocated_before; "allocated_after_B", num allocated_after
          ; "gc_before", gc gc_before; "gc_after", gc gc_after
          ; "last_sha256", str (Digestif.SHA256.to_hex !last) ]))
        [ "old", old_digest; "new", new_digest; "new", new_digest; "old", old_digest ]
    done) (strata ());
  emit (`Assoc [ "kind", str "complete"; "strata", int 14; "phase_rows", int !rows_emitted
    ; "native_or_typed_or_service_gain", `Bool false ])
;;
