(** Personality-text drift diagnostic helpers for keeper runtime.

    Compares the persisted [keeper_meta] personality fields against
    the TOML-source persona defaults using
    [Keeper_personality_io.compare_normalized], surfacing per-field
    drift with byte-length + first-diff-offset diagnostics. Used by
    runtime re-sync logging on the cycle where a re-sync actually
    fires.

    Pure functions over [Keeper_personality_io.coerced_personality]
    + [Keeper_config.prompt_render_max_bytes]. Verbatim extract from
    the head of [Keeper_runtime]; the parent retains 4 single-line
    value aliases. *)

(** #10269: trimmed text equality used by re-sync decision.  Wraps each
    input as a [will] field of a [coerced_personality] record then
    delegates to [Keeper_personality_io.compare_normalized]. *)
let personality_text_equal a b =
  let one_field s : Keeper_personality_io.coerced_personality =
    { Keeper_personality_io.will = s; needs = ""; desires = ""; instructions = "" }
    |> Keeper_personality_io.to_prompt_form
         ~max_bytes:Keeper_config.prompt_render_max_bytes
    |> Keeper_personality_io.coerce
  in
  match Keeper_personality_io.compare_normalized (one_field a) (one_field b) with
  | `Equal -> true
  | `Drift _ -> false

(** Single-field diff entry: "<field>(cur=<len>,tgt=<len>,diff@<pos>)".
    Returns [None] iff the two strings are byte-equal after the same
    trimming used by [personality_text_equal]. *)
let personality_field_diff_entry name current target =
  let one_field s : Keeper_personality_io.coerced_personality =
    Keeper_personality_io.coerce
      { will = s; needs = ""; desires = ""; instructions = "" }
  in
  match
    Keeper_personality_io.compare_normalized (one_field current) (one_field target)
  with
  | `Equal -> None
  | `Drift diffs ->
      (match diffs with
       | [] -> None
       | d :: _ ->
           Some
             (Printf.sprintf "%s(cur=%d,tgt=%d,diff@%d)" name
                d.current_bytes d.target_bytes d.diff_offset))

(** Batch driver over a [(field, current, target)] list. *)
let personality_diff_summary fields =
  List.filter_map
    (fun (name, current, target) ->
      personality_field_diff_entry name current target)
    fields

let utf8_char_width s i =
  let byte = Char.code s.[i] in
  if byte land 0x80 = 0 then 1
  else if byte land 0xE0 = 0xC0 then 2
  else if byte land 0xF0 = 0xE0 then 3
  else if byte land 0xF8 = 0xF0 then 4
  else 1

let truncate_utf8_prefix ~max_bytes s =
  let len = String.length s in
  if len <= max_bytes then s, false
  else
    let rec loop i =
      if i >= len then i
      else
        let next = i + utf8_char_width s i in
        if next > max_bytes then i else loop next
    in
    String.sub s 0 (loop 0), true

let quote_log_preview s =
  let buf = Buffer.create (String.length s + 2) in
  Buffer.add_char buf '"';
  String.iter
    (fun c ->
       match c with
       | '"' -> Buffer.add_string buf "\\\""
       | '\\' -> Buffer.add_string buf "\\\\"
       | '\n' -> Buffer.add_string buf "\\n"
       | '\r' -> Buffer.add_string buf "\\r"
       | '\t' -> Buffer.add_string buf "\\t"
       | c ->
         let code = Char.code c in
         if code < 0x20 || code = 0x7F
         then Buffer.add_string buf (Printf.sprintf "\\x%02x" code)
         else Buffer.add_char buf c)
    s;
  Buffer.add_char buf '"';
  Buffer.contents buf

(** Per-call helper used at runtime re-sync sites.  Different output
    shape from [personality_field_diff_entry]:
    [field(raw_meta_len=N raw_target_len=N trim_meta=S trim_target=S)]
    so dashboards can distinguish raw-length drift from trimmed-content
    drift.  Returns [None] when the two trim-equal so steady-state
    keepers stay quiet.  Trimmed previews truncated to 32 bytes each
    to keep a wide [instructions] field log-friendly.  UTF-8 bytes are
    preserved for operator readability; only quotes, backslashes, and
    control characters are escaped. *)
let personality_field_diff_summary ~field ~current ~target =
  if personality_text_equal current target then None
  else
    let preview s =
      let trimmed = String.trim s in
      let prefix, truncated = truncate_utf8_prefix ~max_bytes:32 trimmed in
      quote_log_preview (if truncated then prefix ^ "..." else prefix)
    in
    Some
      (Printf.sprintf
         "%s(raw_meta_len=%d raw_target_len=%d trim_meta=%s trim_target=%s)"
         field
         (String.length current) (String.length target)
         (preview current) (preview target))
