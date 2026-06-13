(** Deterministic projection from keeper continuity snapshots to working state. *)

module Snapshot = Keeper_memory_policy
module State = Keeper_working_state

type source_field =
  | Next_item

let source_field_name = function
  | Next_item -> "next_items"

let source_field_why = function
  | Next_item -> "keeper_state_snapshot.next_items"


let normalized_items values =
  values |> List.filter_map String_util.trim_nonempty |> Json_util.dedupe_keep_order

let digest12 text =
  let digest = Digest.string text |> Digest.to_hex in
  String.sub digest 0 12

let loop_id ~source ~index text =
  Printf.sprintf "snapshot-%s-%02d-%s"
    (source_field_name source)
    (index + 1)
    (digest12 text)

let evidence_refs ~trace_id ~keeper_turn_id ~source ~index =
  [ State.make_evidence_ref ~kind:"trace_id" ~target:trace_id
  ; State.make_evidence_ref ~kind:"keeper_turn_id"
      ~target:(string_of_int keeper_turn_id)
  ; State.make_evidence_ref ~kind:"state_snapshot_field"
      ~target:
        (Printf.sprintf "%s[%d]" (source_field_name source) index)
  ]

let six_w ~keeper_name ~trace_id ~updated_at_iso ~source text =
  State.make_six_w ~who:keeper_name ~what:text ~when_:updated_at_iso
    ~where_:(Printf.sprintf "trace:%s" trace_id)
    ~why:(source_field_why source)
    ~how:"projected from the latest keeper state snapshot sidecar"

let loops_of_items ~keeper_name ~trace_id ~keeper_turn_id ~updated_at_iso
    ~updated_at_unix ~source items =
  items
  |> List.mapi (fun index text ->
         State.make_loop
           ~id:(loop_id ~source ~index text)
           ~title:text
           ~six_w:(six_w ~keeper_name ~trace_id ~updated_at_iso ~source text)
           ~evidence_refs:(evidence_refs ~trace_id ~keeper_turn_id ~source ~index)
           ~updated_at_unix
           ())

let of_state_snapshot ~keeper_name ~trace_id ~keeper_turn_id ~updated_at_iso
    ~updated_at_unix (snapshot : Snapshot.keeper_state_snapshot) =
  let next_items = normalized_items snapshot.next_items in
  let active_loops =
    loops_of_items ~keeper_name ~trace_id ~keeper_turn_id ~updated_at_iso
      ~updated_at_unix ~source:Next_item next_items
  in
  State.compact { State.empty with active_loops }

let active_open_loop_count_of_state_snapshot
    (snapshot : Snapshot.keeper_state_snapshot) =
  List.length (normalized_items snapshot.next_items)
