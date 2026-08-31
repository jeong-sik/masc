open Keeper_memory_os_types

type measurement =
  { actual_bytes : int
  ; max_bytes : int
  }

type fit =
  | Fits of measurement
  | Exceeds of measurement

(* [first_seen] is on the fact, persisted, and encoded on the wire — it was the
   one field the rendered line dropped. The Keeper prompt tells the model that
   memory "records what was true when it was written: verify time-sensitive
   claims against live state before acting on them", which it cannot do from a
   line that never says when. Live case (2026-08-06): a constraint recorded
   from a transient build-lock condition read as a standing prohibition and a
   Keeper refused every open Task on it. *)
let recorded_at fact = Masc_domain.iso8601_of_unix_seconds fact.first_seen

let render_fact fact =
  Printf.sprintf
    "- [category=%s recorded=%s origin=%s] %s"
    (category_to_string fact.category)
    (recorded_at fact)
    (origin_kind_to_string fact.origin.kind)
    fact.claim
;;

let render_facts facts =
  facts |> List.map render_fact |> String.concat "\n"
;;

let saturated_add left right =
  if left > Int.max_int - right then Int.max_int else left + right
;;

(* Count the exact rendered shape without allocating the combined payload.
   No identity is rendered: the digest was decoration for the Keeper (no
   tool consumes it) and a stale-copy contamination source for the Librarian
   (masc#29558), which now selects through per-pass surrogate ids. *)
let rendered_bytes facts =
  let line_bytes fact =
    0
    |> saturated_add (String.length "- [category=")
    |> saturated_add (String.length (category_to_string fact.category))
    |> saturated_add (String.length " recorded=")
    |> saturated_add (String.length (recorded_at fact))
    |> saturated_add (String.length " origin=")
    |> saturated_add (String.length (origin_kind_to_string fact.origin.kind))
    |> saturated_add (String.length "] ")
    |> saturated_add (String.length fact.claim)
  in
  let bytes, _ =
    List.fold_left
      (fun (bytes, first) fact ->
         let bytes = if first then bytes else saturated_add bytes 1 in
         saturated_add bytes (line_bytes fact), false)
      (0, true)
      facts
  in
  bytes
;;

let measure ~max_bytes facts =
  let actual_bytes = rendered_bytes facts in
  let measurement = { actual_bytes; max_bytes } in
  if actual_bytes <= max_bytes then Fits measurement else Exceeds measurement
;;
