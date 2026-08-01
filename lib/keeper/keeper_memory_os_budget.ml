open Keeper_memory_os_types

type measurement =
  { actual_bytes : int
  ; max_bytes : int
  }

type fit =
  | Fits of measurement
  | Exceeds of measurement

let render_fact fact =
  Printf.sprintf
    "- [memory_id=%s category=%s] %s"
    (memory_id fact)
    (category_to_string fact.category)
    fact.claim
;;

let render_facts facts =
  facts |> List.map render_fact |> String.concat "\n"
;;

let memory_id_bytes = String.length "sha256:" + (Digestif.SHA256.digest_size * 2)

let saturated_add left right =
  if left > Int.max_int - right then Int.max_int else left + right
;;

(* Count the exact rendered shape without hashing identities or allocating the
   combined payload. [memory_id] is always sha256 plus a fixed-width hex digest. *)
let rendered_bytes facts =
  let line_bytes fact =
    0
    |> saturated_add (String.length "- [memory_id=")
    |> saturated_add memory_id_bytes
    |> saturated_add (String.length " category=")
    |> saturated_add (String.length (category_to_string fact.category))
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
