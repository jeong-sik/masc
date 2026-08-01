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

let measure ~max_bytes facts =
  let actual_bytes = String.length (render_facts facts) in
  let measurement = { actual_bytes; max_bytes } in
  if actual_bytes <= max_bytes then Fits measurement else Exceeds measurement
;;
