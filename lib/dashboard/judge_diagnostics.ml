(* #9774: shared helpers for governance / operator judge LLM-output
   diagnostics. Pure string transforms — no logging, no I/O. *)

(* Truncate a string to at most [max_bytes] bytes, appending an ellipsis
   marker that records how many bytes were dropped. Byte-count is
   acceptable here because the consumer is a log line, not a UI surface. *)
let truncate_with_marker ?(max_bytes = 500) s =
  let len = String.length s in
  if len <= max_bytes
  then s
  else String.sub s 0 max_bytes ^ Printf.sprintf "…[+%d chars]" (len - max_bytes)
;;

(* When a judge's [Lenient_json.parse] returns the [`Assoc [("raw", _)]]
   fallback, format a single message that names the judge, the raw size,
   and a bounded preview. The same string is used both as the warn log
   payload and as the [Error] returned upstream so any consumer sees the
   diagnostic without enabling raw provider logging. *)
let format_lenient_fallback ~judge_label raw =
  Printf.sprintf
    "%s judge returned unparseable response (Lenient_json fallback hit; %d chars; \
     preview: %s)"
    judge_label
    (String.length raw)
    (truncate_with_marker raw)
;;
