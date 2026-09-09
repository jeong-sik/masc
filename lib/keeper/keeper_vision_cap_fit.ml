type verdict =
  | Sends_as_is
  | Shrink_longest_edge_to of int
  | Cannot_fit of
      { needed_bytes : int
      ; cap_bytes : int
      }

(* Measured on 2026-09-07 against the vision walk's request: the prompt
   around the query is under 300 bytes and the generation parameters under
   200. 4 KiB leaves room for a provider adapter that adds fields. *)
let envelope_allowance_bytes = 4096

let shrink_margin = 0.9

(* Standard base64: every 3 input bytes become 4, the last group padded. *)
let base64_length n = (n + 2) / 3 * 4

let needed_bytes ~image_bytes ~query_bytes =
  base64_length image_bytes + query_bytes + envelope_allowance_bytes
;;

let plan ~cap_bytes ~image_bytes ~query_bytes ~longest_edge ~min_edge =
  let needed_bytes = needed_bytes ~image_bytes ~query_bytes in
  let cannot_fit = Cannot_fit { needed_bytes; cap_bytes } in
  if needed_bytes <= cap_bytes
  then Sends_as_is
  else (
    match longest_edge with
    | None -> cannot_fit
    | Some edge ->
      (* Raw bytes the cap leaves for the image once base64 expansion, the
         query and the envelope are taken out. *)
      let budget_bytes = (cap_bytes - query_bytes - envelope_allowance_bytes) * 3 / 4 in
      if budget_bytes <= 0 || edge <= 0 || image_bytes <= 0
      then cannot_fit
      else (
        (* Encoded size grows with pixel count, so with the square of the
           edge; the edge that fits scales with the square root of the byte
           ratio. *)
        let ratio =
          Float.sqrt (float_of_int budget_bytes /. float_of_int image_bytes)
        in
        let fitted_edge = int_of_float (float_of_int edge *. ratio *. shrink_margin) in
        if fitted_edge < min_edge || fitted_edge >= edge
        then cannot_fit
        else Shrink_longest_edge_to fitted_edge))
;;
