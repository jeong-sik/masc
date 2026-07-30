(** Runtime_kimi_sanitizer — Auto-healing sanitizer for broken Kimi provider wire chunks. *)

let re_finish_reason_corrupted = Re.Pcre.regexp "finish_reasonhoices"

let sanitize_wire_chunk raw =
  if Re.Pcre.pmatch ~rex:re_finish_reason_corrupted raw then
    Re.Pcre.substitute ~rex:re_finish_reason_corrupted ~subst:(fun _ ->
      "finish_reason\": null}, \"choices"
    ) raw
  else
    raw
