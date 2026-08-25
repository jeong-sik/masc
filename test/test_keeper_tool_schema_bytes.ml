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

let measured ~surface =
  let schemas = Masc.Keeper_tool_descriptor.model_visible_schemas ~surface in
  let bytes =
    List.fold_left
      (fun acc schema -> acc + String.length (Yojson.Safe.to_string (schema_json schema)))
      0
      schemas
  in
  (List.length schemas, bytes)
;;

(* RFC-0389 backward-compat golden: a Keeper with no [keeper.tools] declaration
   (surface = All) must keep the tool surface it had before that feature, so a
   later refactor cannot quietly take a tool away from the Keepers that never
   opted in. Pinned on 2026-08-23 from the pre-feature surface.

   Re-pin only with the PR that moves the surface, and say what the move bought.
   The two earlier re-pins also restated the new numbers in this comment, and
   both restatements drifted from the values three lines below (it read 68,881
   bytes at 82 tools against 72,787 at 86), so this one names no number that
   lives in the code.

   2026-08-25: re-pinned for [keeper_code_query], the language-server tool added
   in #30539. That PR wired the tool through the descriptor and the catalog but
   never ran this file, so main went red on the count and stayed red for every
   other PR until an unrelated review noticed it. What the growth bought is a
   question a Keeper could not ask before: where a name is defined and what its
   type is, answered from the compiler's view of the code rather than from a
   text match. *)

(* 2026-08-25, an hour later: 74,267 -> 74,521 for the same tool. #30571 grew
   the [keeper_code_query] description to say that [references] needs the
   project's reference index, and merged twelve minutes before the re-pin
   above, which had measured the surface before it. Neither PR touched a file
   the other did, so nothing conflicted and both were right on their own — the
   merge order alone produced a number that matched neither. A byte count
   pinned in one file and moved from another has no way to notice that; what
   notices is running this file, which is the same thing all four of today's
   red causes needed. *)
let all_surface_golden_count = 87
let all_surface_golden_bytes = 74_521

let test_all_surface_is_unchanged () =
  let count, bytes = measured ~surface:All in
  check int "All surface tool count unchanged" all_surface_golden_count count;
  check int "All surface bytes unchanged" all_surface_golden_bytes bytes
;;

(* RFC-0389: a Declared surface must be strictly smaller than All — that is the
   whole point of the feature. Core/Meta are always retained, so a Declared
   surface is never empty. *)
let test_declared_surface_is_smaller_than_all () =
  let _, all_bytes = measured ~surface:All in
  let declared_surfaces =
    [ Masc.Keeper_tool_descriptor.Declared
        { groups = [ Masc.Keeper_tool_group.Board_group ] }
    ; Masc.Keeper_tool_descriptor.Declared
        { groups =
            [ Masc.Keeper_tool_group.Board_group
            ; Masc.Keeper_tool_group.Workspace_group
            ]
        }
    ; Masc.Keeper_tool_descriptor.Declared
        { groups =
            [ Masc.Keeper_tool_group.Memory_group
            ; Masc.Keeper_tool_group.Surface_group
            ]
        }
    ]
  in
  List.iter
    (fun surface ->
      let count, bytes = measured ~surface in
      check bool "Declared surface is non-empty" true (count > 0);
      check bool "Declared surface is smaller than All" true (bytes < all_bytes))
    declared_surfaces
;;

let test_tool_schema_bytes_stay_under_the_ceiling () =
  let count, bytes = measured ~surface:All in
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
  let _, bytes = measured ~surface:All in
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
    ; ( "RFC-0389 per-keeper surface"
      , [ test_case "All surface is unchanged (backward compat)" `Quick
            test_all_surface_is_unchanged
        ; test_case "Declared surface is smaller than All" `Quick
            test_declared_surface_is_smaller_than_all
        ] )
    ]
;;
