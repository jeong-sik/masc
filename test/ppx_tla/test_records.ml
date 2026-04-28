(* Cycle 19 / Tier I7 tests for ppx_tla [@@deriving tla] on record types.

   Records emit:
   - [field_names : string list]: source-order field names
   - [field_count : int]: [List.length field_names]

   The deriver does NOT inspect or render field values — that is left to
   future tiers (and to user-supplied per-field combinators). The minimal
   shape-helper API is sufficient for TLA+ structural-shape assertions
   that need to enumerate fields without knowing their types.

   Modules below wrap each record type so [field_names] / [field_count]
   stay namespaced. *)

module Conditions = struct
  type t = {
    healthy : bool;
    overflow : bool;
    has_pending_compaction : bool;
    awaiting_approval : bool;
  }
  [@@deriving tla]
end

module Single_field = struct
  type t = { only : int } [@@deriving tla]
end

module Mixed_types = struct
  type t = {
    name : string;
    count : int;
    active : bool;
    tags : string list;
  }
  [@@deriving tla]
end

let test_conditions_field_names () =
  assert
    (Conditions.field_names
     = [ "healthy"; "overflow"; "has_pending_compaction"; "awaiting_approval" ])

let test_conditions_field_count () =
  assert (Conditions.field_count = 4)

let test_single_field () =
  assert (Single_field.field_names = [ "only" ]);
  assert (Single_field.field_count = 1)

let test_mixed_types () =
  assert (Mixed_types.field_names = [ "name"; "count"; "active"; "tags" ]);
  assert (Mixed_types.field_count = 4)

(* Source-order preservation: fields must appear in declaration order,
   not alphabetical or hash order. The deriver iterates the AST list
   in order. *)
let test_source_order_preserved () =
  let module Ordered = struct
    type t = { z : int; a : int; m : int } [@@deriving tla]
  end in
  assert (Ordered.field_names = [ "z"; "a"; "m" ]);
  assert (Ordered.field_count = 3)

let () =
  test_conditions_field_names ();
  test_conditions_field_count ();
  test_single_field ();
  test_mixed_types ();
  test_source_order_preserved ();
  print_endline "test_records: all assertions passed"
