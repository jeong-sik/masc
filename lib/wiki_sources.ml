type t =
  { references : int
  ; hearsay : int
  }

let none = { references = 0; hearsay = 0 }
let heading = "## Sources"
let reference_prefixes = [ "repo:"; "board:"; "artifact:"; "url:" ]
let hearsay_prefix = "said:"

let strip_cr line =
  let length = String.length line in
  if length > 0 && Char.equal line.[length - 1] '\r'
  then String.sub line 0 (length - 1)
  else line
;;

let is_fence line =
  let trimmed = String.trim line in
  String.starts_with ~prefix:"```" trimmed || String.starts_with ~prefix:"~~~" trimmed
;;

let is_heading line = String.starts_with ~prefix:"#" line

type state =
  | Before
  | In_section
  | After

let count_line line counts =
  match String.starts_with ~prefix:"- " line with
  | false -> counts
  | true ->
    let item = String.trim (String.sub line 2 (String.length line - 2)) in
    if List.exists (fun prefix -> String.starts_with ~prefix item) reference_prefixes
    then { counts with references = counts.references + 1 }
    else if String.starts_with ~prefix:hearsay_prefix item
    then { counts with hearsay = counts.hearsay + 1 }
    else counts
;;

let of_body body =
  let _, _, counts =
    List.fold_left
      (fun (state, in_fence, counts) raw_line ->
         let line = strip_cr raw_line in
         if is_fence line
         then state, not in_fence, counts
         else if in_fence
         then state, in_fence, counts
         else (
           match state with
           | Before ->
             if String.equal (String.trim line) heading
                && String.starts_with ~prefix:heading line
             then In_section, in_fence, counts
             else Before, in_fence, counts
           | In_section ->
             if is_heading line then After, in_fence, counts
             else In_section, in_fence, count_line line counts
           | After -> After, in_fence, counts))
      (Before, false, none)
      (String.split_on_char '\n' body)
  in
  counts
;;
