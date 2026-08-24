(** A ceiling on the tool schemas every Keeper turn carries.

    [test_keeper_system_prompt_bytes] pins the assembled system prompt, which is
    the smaller half of the fixed per-turn cost. The tool array is the larger
    one and had no measurement at all: a tool added with a generous schema, or a
    description that grows a paragraph at a time, costs every turn of every
    Keeper and nothing said so.

    This is a ratchet, not a golden. Shrinking passes and reports the slack, so
    a PR that trims a description is never asked to edit a number to stay green
    — a ratchet that fails on its own improvement takes main red for the
    duration. Growth past the ceiling fails and has to be argued for in
    the PR that causes it.

    What is measured is what the model receives: [model_visible_schemas]
    projects the descriptors a Keeper can call, and each carries the name,
    description, and input_schema that go on the wire. Serialized as compact
    JSON, so whitespace in the OCaml source does not move the number. *)

open Alcotest

(* Raise only with the PR that grows the surface, and say what it bought.
   2026-08-07: 72,485 bytes across 98 model-visible tools — 7.9x the assembled
   system prompt (9,167 bytes, pinned next door). The headroom is deliberate
   slack for one ordinary tool, not room to grow into.

   2026-08-23: 85,000. What it bought is nothing, and that is the finding. The
   surface reached 88,138 bytes across 95 tools — three fewer tools carrying
   15,653 more bytes — with no PR to attribute it to: 45 commits touched
   lib/tool_surface and the descriptor over those two weeks and the growth is
   spread across them. The same PR that moves this number takes 4,288 bytes
   back out of [Execute], whose redirect objects spelled "exactly one of these
   keys" as a oneOf branch per pair of property names.

   What is left to take is measured and not taken here. The Execute schema
   ships the same prose several times over — the argv paragraph four times, the
   fd sentence eight — because the exec-stage shape repeats at the top level,
   inside pipeline, inside then, and inside then's pipeline. That is 4,158
   bytes of duplicated description, and JSON Schema names the fix ($defs and
   $ref); nothing in this repository sends a $ref to a model yet, so whether
   every provider resolves one is unverified and not a thing to guess at on the
   surface every turn carries. Verify it, then collapse the repeats and bring
   this number back down. *)
let ceiling_bytes = 85_000

let schema_json (schema : Masc_domain.tool_schema) =
  `Assoc
    [ "name", `String schema.name
    ; "description", `String schema.description
    ; "input_schema", schema.input_schema
    ]
;;

let measured () =
  let schemas = Masc.Keeper_tool_descriptor.model_visible_schemas () in
  let bytes =
    List.fold_left
      (fun acc schema -> acc + String.length (Yojson.Safe.to_string (schema_json schema)))
      0
      schemas
  in
  (List.length schemas, bytes)
;;

let test_tool_schema_bytes_stay_under_the_ceiling () =
  let count, bytes = measured () in
  check bool "the surface is non-empty" true (count > 0);
  if bytes > ceiling_bytes
  then
    failf
      "model-visible tool schemas grew to %d bytes across %d tools, over the %d ceiling \
       by %d.\n\
       Every Keeper turn carries this. Trim the schema or the description, or raise \
       ceiling_bytes in this file with the PR that needs the room and say what it bought."
      bytes
      count
      ceiling_bytes
      (bytes - ceiling_bytes)
;;

(* A ceiling nobody is near stops measuring anything. This fails when the slack
   grows past a third of the ceiling, which is the signal to lower it and bank
   the reduction: a baseline that has drifted far from what it measures is
   reporting on nothing. *)
let test_the_ceiling_still_tracks_the_surface () =
  let _, bytes = measured () in
  let slack = ceiling_bytes - bytes in
  if bytes <= ceiling_bytes && slack > ceiling_bytes / 3
  then
    failf
      "model-visible tool schemas are %d bytes against a %d ceiling — %d of slack. The \
       ceiling has stopped tracking the surface; lower it to bank the reduction."
      bytes
      ceiling_bytes
      slack
;;

let () =
  run
    "keeper_tool_schema_bytes"
    [ ( "per-turn tool surface"
      , [ test_case "stays under the ceiling" `Quick
            test_tool_schema_bytes_stay_under_the_ceiling
        ; test_case "the ceiling still tracks the surface" `Quick
            test_the_ceiling_still_tracks_the_surface
        ] )
    ]
;;
