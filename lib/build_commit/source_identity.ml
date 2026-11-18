(* The source a binary was built from; see source_identity.mli. *)

type state =
  | Clean
  | Modified of { digest : string }

type t =
  { commit : string
  ; state : state
  }

(* The grammar probe-commit.sh writes. *)
let declaration_prefix = "MASC_SOURCE_IDENTITY="
let declaration_terminator = ';'
let state_separator = '/'
let clean_word = "clean"
let modified_word = "modified:"
let sha1_hex_length = 40
let sha256_hex_length = 64

let longest_body_length =
  sha256_hex_length + 1 + String.length modified_word + sha256_hex_length
;;

let is_lowercase_hex c = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')

let is_object_id s =
  let length = String.length s in
  (length = sha1_hex_length || length = sha256_hex_length)
  && String.for_all is_lowercase_hex s
;;

let state_equal a b =
  match a, b with
  | Clean, Clean -> true
  | Modified { digest = a }, Modified { digest = b } -> String.equal a b
  | Clean, Modified _ | Modified _, Clean -> false
;;

let equal a b = String.equal a.commit b.commit && state_equal a.state b.state

let to_string { commit; state } =
  match state with
  | Clean -> Printf.sprintf "%s%c%s" commit state_separator clean_word
  | Modified { digest } ->
    Printf.sprintf "%s%c%s%s" commit state_separator modified_word digest
;;

let suffix_after ~prefix s =
  if String.starts_with ~prefix s
  then
    Some
      (String.sub s (String.length prefix) (String.length s - String.length prefix))
  else None
;;

let state_of_string s =
  if String.equal s clean_word
  then Some Clean
  else
    match suffix_after ~prefix:modified_word s with
    | Some digest when is_object_id digest -> Some (Modified { digest })
    | Some _ | None -> None
;;

let of_string s =
  match String.index_opt s state_separator with
  | None -> None
  | Some at ->
    let commit = String.sub s 0 at in
    let rest = String.sub s (at + 1) (String.length s - at - 1) in
    if is_object_id commit
    then Option.map (fun state -> { commit; state }) (state_of_string rest)
    else None
;;

let declaration t =
  Printf.sprintf "%s%s%c" declaration_prefix (to_string t) declaration_terminator
;;

type scan =
  | Declared of t
  | Undeclared
  | Several of t list

(* The first [needle] at or after [pos]. *)
let find_from haystack ~pos needle =
  let needle_length = String.length needle in
  let last = String.length haystack - needle_length in
  let rec at i =
    if i > last
    then None
    else if String.equal (String.sub haystack i needle_length) needle
    then Some i
    else
      match String.index_from_opt haystack (i + 1) needle.[0] with
      | Some next -> at next
      | None -> None
  in
  if needle_length = 0 || pos > last
  then None
  else
    match String.index_from_opt haystack pos needle.[0] with
    | Some first -> at first
    | None -> None
;;

(* The terminator within the longest body after [start], if any. *)
let terminator_after haystack ~start =
  let limit = min (String.length haystack) (start + longest_body_length + 1) in
  let rec at i =
    if i >= limit
    then None
    else if Char.equal haystack.[i] declaration_terminator
    then Some i
    else at (i + 1)
  in
  at start
;;

let scan bytes =
  let prefix_length = String.length declaration_prefix in
  let rec collect pos found =
    match find_from bytes ~pos declaration_prefix with
    | None -> List.rev found
    | Some at ->
      let start = at + prefix_length in
      let found =
        match terminator_after bytes ~start with
        | None -> found
        | Some stop ->
          (match of_string (String.sub bytes start (stop - start)) with
           | Some identity when not (List.exists (equal identity) found) ->
             identity :: found
           | Some _ | None -> found)
      in
      collect (at + 1) found
  in
  match collect 0 [] with
  | [] -> Undeclared
  | [ identity ] -> Declared identity
  | _ :: _ :: _ as several -> Several several
;;

(* Parsed at run time from the generated literal, so the literal is what
   every binary carries and what {!scan} finds in it. *)
let current =
  match Build_commit_generated.source_identity_declaration with
  | None -> None
  | Some generated ->
    (match scan generated with
     | Declared identity -> Some identity
     | Undeclared | Several _ -> None)
;;
