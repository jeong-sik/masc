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

let file_change_evidence application =
  match application.line_occurrences with
  | Some occurrences -> Keeper_file_change_evidence.edited occurrences
  | None ->
    Keeper_file_change_evidence.edited_ranges_omitted
      ~occurrence_count:application.occurrence_count
;;
