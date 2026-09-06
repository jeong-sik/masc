(* RFC-0006 Phase A.4: replace [old] with [new] in [text]. When
   [replace_all=false], requires exactly one occurrence so accidental
   multi-edits are rejected (mirrors Edit semantics). Pure, so the host
   handler and the remote-lane handler apply the same patch. *)
type patch_application =
  { updated : string
  ; occurrence_count : int
  ; line_occurrences : Keeper_file_change_evidence.edit_occurrence list option
  }

let apply_patch ~old_string ~new_string ~replace_all text =
  if old_string = ""
  then Error "old_string must be non-empty for mode=patch."
  else (
    let count_occurrences ~needle haystack =
      let nlen = String.length needle in
      if nlen = 0
      then 0
      else (
        let hlen = String.length haystack in
        let rec loop i acc =
          if i + nlen > hlen
          then acc
          else if String.sub haystack i nlen = needle
          then loop (i + nlen) (acc + 1)
          else loop (i + 1) acc
        in
        loop 0 0)
    in
    let occurrence_count = count_occurrences ~needle:old_string text in
    if occurrence_count = 0
    then Error "old_string not found in file. Patch did not match anything."
    else if (not replace_all) && occurrence_count > 1
    then
      Error
        (Printf.sprintf
           "old_string occurs %d times. Pass replace_all=true to apply to all, or supply \
            a more specific old_string."
           occurrence_count)
    else (
      let buf = Buffer.create (String.length text) in
      let nlen = String.length old_string in
      let hlen = String.length text in
      let record_line_occurrences =
        occurrence_count
        <= Keeper_file_change_evidence.max_recorded_edit_occurrences
      in
      let rec loop i old_line new_line evidence_rev =
        if i + nlen > hlen
        then (
          Buffer.add_substring buf text i (hlen - i);
          Option.map List.rev evidence_rev)
        else if String.sub text i nlen = old_string
        then (
          let evidence_rev =
            Option.map
              (fun evidence_rev ->
                 Keeper_file_change_evidence.edit_occurrence
                   ~old_start_line:old_line
                   ~new_start_line:new_line
                   ~old_string
                   ~new_string
                 :: evidence_rev)
              evidence_rev
          in
          Buffer.add_string buf new_string;
          if replace_all
          then
            loop
              (i + nlen)
              (Keeper_file_change_evidence.advance_line
                 ~start_line:old_line
                 old_string)
              (Keeper_file_change_evidence.advance_line
                 ~start_line:new_line
                 new_string)
              evidence_rev
          else (
            Buffer.add_substring buf text (i + nlen) (hlen - i - nlen);
            Option.map List.rev evidence_rev))
        else (
          let char = text.[i] in
          Buffer.add_char buf char;
          let line_delta = if Char.equal char '\n' then 1 else 0 in
          loop
            (i + 1)
            (old_line + line_delta)
            (new_line + line_delta)
            evidence_rev)
      in
      let line_occurrences =
        loop 0 1 1 (if record_line_occurrences then Some [] else None)
      in
      Ok { updated = Buffer.contents buf; occurrence_count; line_occurrences }))
;;

type operation =
  | Replace of
      { old_string : string
      ; new_string : string
      ; replace_all : bool
      }
  | Insert_before_line of
      { line : int
      ; text : string
      }

let operation_label = function
  | Replace _ -> "replace"
  | Insert_before_line _ -> "insert_before_line"
;;

let is_blank_char c = Char.equal c ' ' || Char.equal c '\t'

(* The lines of [content], counted the way an editor shows them: a file
   ending in a line break has no extra empty line after it. *)
let line_count content =
  let len = String.length content in
  if len = 0
  then 0
  else (
    let breaks = ref 0 in
    String.iter (fun c -> if Char.equal c '\n' then incr breaks) content;
    if Char.equal content.[len - 1] '\n' then !breaks else !breaks + 1)
;;

let insert_before_line ~line ~text content =
  let len = String.length content in
  if line < 1
  then Error (Printf.sprintf "insert_before_line must be >= 1, got %d." line)
  else if String.equal text ""
  then Error "insert_text must be non-empty."
  else if String.contains text '\n'
  then Error "insert_text is one line and cannot contain a line break."
  else if len = 0
  then Error "the file is empty; there is no line to insert above."
  else (
    let rec start_of current offset =
      if current = line
      then Some offset
      else (
        match String.index_from_opt content offset '\n' with
        | None -> None
        | Some break -> start_of (current + 1) (break + 1))
    in
    match start_of 1 0 with
    | Some offset when offset < len ->
      let line_end =
        match String.index_from_opt content offset '\n' with
        | Some break -> break + 1
        | None -> len
      in
      let current_line = String.sub content offset (line_end - offset) in
      let indent_len =
        let rec walk i = if i < String.length current_line && is_blank_char current_line.[i] then walk (i + 1) else i in
        walk 0
      in
      let inserted = String.sub current_line 0 indent_len ^ text ^ "\n" in
      let updated =
        String.sub content 0 offset ^ inserted ^ String.sub content offset (len - offset)
      in
      let occurrence =
        Keeper_file_change_evidence.edit_occurrence
          ~old_start_line:line
          ~new_start_line:line
          ~old_string:current_line
          ~new_string:(inserted ^ current_line)
      in
      Ok { updated; occurrence_count = 1; line_occurrences = Some [ occurrence ] }
    | Some _ | None ->
      Error
        (Printf.sprintf
           "the file has %d line%s; line %d does not exist."
           (line_count content)
           (if line_count content = 1 then "" else "s")
           line))
;;

let apply operation content =
  match operation with
  | Replace { old_string; new_string; replace_all } ->
    apply_patch ~old_string ~new_string ~replace_all content
  | Insert_before_line { line; text } -> insert_before_line ~line ~text content
;;

let file_change_evidence application =
  match application.line_occurrences with
  | Some occurrences -> Keeper_file_change_evidence.edited occurrences
  | None ->
    Keeper_file_change_evidence.edited_ranges_omitted
      ~occurrence_count:application.occurrence_count
;;
