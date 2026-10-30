let label name =
  String.split_on_char '_' name
  |> List.map (fun segment ->
         if segment = "" then "" else String.capitalize_ascii segment)
  |> String.concat ""

(* The tools list mixes wire tool names with skill slugs such as
   "browser-lanes". A slug is already the human-readable name, and Pascal-
   casing it would only mangle it ("Browser-lanes"); any name containing '-'
   is taken to be a slug and passes through unchanged. This stays a rule, not
   a hand-written exception table. *)
let list_label name = if String.contains name '-' then name else label name
