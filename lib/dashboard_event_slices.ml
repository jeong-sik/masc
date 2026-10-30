(* Which dashboard slice each pushed event type is delivered on.

   Both ends of the wire need this. The server routes by it and rejects
   subscriptions to a slice outside its image; the terminal client classifies
   by it, because an event type that carries a whole projection is state the
   server pushed rather than something a keeper did.

   It lived in the WebSocket transport, and every reader that could not link
   the server library kept a copy instead. Three had:

     - the subscription acceptor's own slice list, which drifted from this one
       for a day after #27027 with nothing to catch it
     - the transport test's [mapped_sse_event_types], a hand-kept literal whose
       comment recorded that a new arm had to be added there too
     - the terminal client's event decoder, which named three of the five and
       so read [operator_digest] and [transport_health_snapshot] as event types
       it had never been taught

   One table, read by all of them. The pairs are the definition: the slice
   names are its image rather than a second list, so a slice cannot be
   accepted that no event reaches. *)

type entry = {
  event_type : string;  (** the [type] field the server puts on the wire *)
  slice : string;  (** the subscription slice it is delivered on *)
  whole_projection : bool;
      (** [true] when the event carries a whole projection and the payload can
          be dropped once the name is known; [false] for a delta, which a
          reader has to apply. *)
}

(* "namespace_truth_snapshot" was delivered here alongside the canonical name
   while both were broadcast. Only one is now (#27664). *)
let entries =
  [
    { event_type = "project_snapshot"; slice = "namespace"; whole_projection = true };
    { event_type = "execution_snapshot"; slice = "execution"; whole_projection = true };
    { event_type = "operator_snapshot"; slice = "operator"; whole_projection = true };
    { event_type = "operator_digest"; slice = "operator"; whole_projection = true };
    { event_type = "transport_health_snapshot"; slice = "transport"; whole_projection = true };
    { event_type = "keeper_composite_changed"; slice = "composite"; whole_projection = false };
  ]

let entry_for event_type =
  List.find_opt (fun entry -> String.equal entry.event_type event_type) entries

let slice_for_sse_type event_type =
  Option.map (fun entry -> entry.slice) (entry_for event_type)

let carries_whole_projection event_type =
  match entry_for event_type with
  | Some entry -> entry.whole_projection
  | None -> false

let slices = List.sort_uniq compare (List.map (fun entry -> entry.slice) entries)
let valid_slice slice = List.mem slice slices
