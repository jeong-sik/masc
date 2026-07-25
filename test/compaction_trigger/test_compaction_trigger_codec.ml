(* Codec conformance for Compaction_trigger, including the measured-capacity origin.

   of_detail_json is documented as the exact inverse of to_detail_json, so every
   variant is round-tripped rather than only encoded. The rejection cases matter as
   much as the round trips: a decoder that accepts a row it should refuse turns a
   durable observation into a value nobody can trust. *)

let failures = ref 0

let check name condition =
  if condition then print_endline ("ok   " ^ name)
  else begin
    incr failures;
    print_endline ("FAIL " ^ name)
  end
;;

let roundtrip name (trigger : Compaction_trigger.t) =
  match Compaction_trigger.of_detail_json (Compaction_trigger.to_detail_json trigger) with
  | Ok decoded -> check name (decoded = trigger)
  | Error error ->
    incr failures;
    print_endline
      ("FAIL " ^ name ^ ": " ^ Compaction_trigger.decode_error_to_string error)
;;

let rejects name json =
  match Compaction_trigger.of_detail_json json with
  | Error _ -> print_endline ("ok   " ^ name)
  | Ok _ ->
    incr failures;
    print_endline ("FAIL " ^ name ^ ": accepted a row it must refuse")
;;

let () =
  roundtrip "manual round-trips" Compaction_trigger.Manual;
  roundtrip
    "provider overflow with a declared limit round-trips"
    (Compaction_trigger.Provider_overflow { limit_tokens = Some 1_048_576 });
  roundtrip
    "provider overflow without a limit round-trips"
    (Compaction_trigger.Provider_overflow { limit_tokens = None });
  roundtrip
    "measured byte overflow round-trips"
    (Compaction_trigger.Measured_capacity_exceeded
       { dimension = Compaction_trigger.Serialized_bytes
       ; measured = 453_515
       ; limit = 262_144
       });
  roundtrip
    "measured token overflow round-trips"
    (Compaction_trigger.Measured_capacity_exceeded
       { dimension = Compaction_trigger.Input_tokens; measured = 476_486; limit = 200_000 });

  check
    "measured trigger has its own label"
    (String.equal
       (Compaction_trigger.to_label
          (Compaction_trigger.Measured_capacity_exceeded
             { dimension = Compaction_trigger.Serialized_bytes
             ; measured = 2
             ; limit = 1
             }))
       "measured_capacity_exceeded");
  check
    "human rendering names the dimension and both numbers"
    (String.equal
       (Compaction_trigger.to_human
          (Compaction_trigger.Measured_capacity_exceeded
             { dimension = Compaction_trigger.Serialized_bytes
             ; measured = 453_515
             ; limit = 262_144
             }))
       "measured_capacity_exceeded(dimension=serialized_bytes,measured=453515,limit=262144)");

  (* measured = limit is not an excess. Accepting it would let a trigger claim an
     overflow that did not happen. *)
  rejects
    "measured equal to the limit is refused"
    (`Assoc
      [ "kind", `String "measured_capacity_exceeded"
      ; "dimension", `String "serialized_bytes"
      ; "measured", `Int 100
      ; "limit", `Int 100
      ]);
  rejects
    "measured below the limit is refused"
    (`Assoc
      [ "kind", `String "measured_capacity_exceeded"
      ; "dimension", `String "serialized_bytes"
      ; "measured", `Int 10
      ; "limit", `Int 100
      ]);
  rejects
    "an unknown dimension is refused rather than defaulted"
    (`Assoc
      [ "kind", `String "measured_capacity_exceeded"
      ; "dimension", `String "wall_clock"
      ; "measured", `Int 200
      ; "limit", `Int 100
      ]);
  rejects
    "a missing dimension is refused"
    (`Assoc
      [ "kind", `String "measured_capacity_exceeded"
      ; "measured", `Int 200
      ; "limit", `Int 100
      ]);
  rejects
    "a non-positive measurement is refused"
    (`Assoc
      [ "kind", `String "measured_capacity_exceeded"
      ; "dimension", `String "input_tokens"
      ; "measured", `Int 0
      ; "limit", `Int 100
      ]);
  rejects
    "an unknown field is refused"
    (`Assoc
      [ "kind", `String "measured_capacity_exceeded"
      ; "dimension", `String "input_tokens"
      ; "measured", `Int 200
      ; "limit", `Int 100
      ; "estimated", `Bool true
      ]);

  if !failures = 0 then print_endline "compaction trigger codec: all checks passed"
  else begin
    print_endline (Printf.sprintf "compaction trigger codec: %d failed" !failures);
    exit 1
  end
;;
