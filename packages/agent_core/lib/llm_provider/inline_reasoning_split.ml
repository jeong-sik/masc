(** Splitting reasoning a provider embeds in the content channel. *)

let open_tag = "<think>"
let close_tag = "</think>"

type mode =
  | Outside
  | Inside

type state =
  { mutable mode : mode
  ; mutable pending : string
  }

type snapshot = mode * string

let snapshot state = state.mode, state.pending
let restore state (mode, pending) =
  state.mode <- mode;
  state.pending <- pending

let create () = { mode = Outside; pending = "" }
let inside state = state.mode = Inside

(* Naive search: the haystack here is one delta plus at most a tag's worth of
   held bytes, and the needles are seven and eight bytes long. *)
let find haystack needle =
  let hl = String.length haystack
  and nl = String.length needle in
  if nl = 0 || nl > hl
  then None
  else (
    let last = hl - nl in
    let rec go i =
      if i > last
      then None
      else if String.sub haystack i nl = needle
      then Some i
      else go (i + 1)
    in
    go 0)
;;

(* The longest suffix of [s] that is a proper prefix of [tag]. Those bytes are
   held back: the next delta may complete the tag, and emitting them now would
   put a fragment of "<think>" into the reply. *)
let held_suffix_len s tag =
  let sl = String.length s in
  let rec go k =
    if k = 0
    then 0
    else if String.sub s (sl - k) k = String.sub tag 0 k
    then k
    else go (k - 1)
  in
  go (min sl (String.length tag - 1))
;;

let drop s n = String.sub s n (String.length s - n)

type segment = Text of string | Reasoning of string

let segment mode bytes =
  match mode with Outside -> Text bytes | Inside -> Reasoning bytes

let feed_segments state chunk =
  state.pending <- state.pending ^ chunk;
  let rec loop acc =
    let target = match state.mode with Outside -> open_tag | Inside -> close_tag in
    match find state.pending target with
    | Some i ->
      let acc =
        if i = 0 then acc
        else segment state.mode (String.sub state.pending 0 i) :: acc
      in
      state.pending <- drop state.pending (i + String.length target);
      state.mode <- (match state.mode with Outside -> Inside | Inside -> Outside);
      loop acc
    | None ->
      let held = held_suffix_len state.pending target in
      let emitted = String.length state.pending - held in
      let acc =
        if emitted = 0 then acc
        else segment state.mode (String.sub state.pending 0 emitted) :: acc
      in
      state.pending <- drop state.pending emitted;
      List.rev acc
  in
  loop []
;;

let flush_segments state =
  let rest = state.pending in
  state.pending <- "";
  if rest = "" then [] else [segment state.mode rest]
;;

(* Compare the typed byte stream, not delta boundaries chosen by transport. *)
let[@warning "-32"] test_typed_bytes segments =
  List.concat_map (function
    | Text bytes -> List.init (String.length bytes) (fun i -> Outside, bytes.[i])
    | Reasoning bytes -> List.init (String.length bytes) (fun i -> Inside, bytes.[i])) segments

let[@warning "-32"] test_partition input cuts =
  let state = create () in
  let rec feed_from offset = function
    | [] -> feed_segments state (drop input offset)
    | cut :: rest ->
      let head = feed_segments state (String.sub input offset (cut - offset)) in
      head @ feed_from cut rest
  in
  let segments = feed_from 0 cuts in
  test_typed_bytes (segments @ flush_segments state)

let%test "ordered segments preserve text reasoning text within one delta" =
  feed_segments (create ()) "A<think>B</think>C<think>D</think>E"
  = [Text "A"; Reasoning "B"; Text "C"; Reasoning "D"; Text "E"]

let%test "every two-cut partition preserves typed bytes including partial tags" =
  let cases =
    [ "A<think>B</think>C<think>D</think>E",
      [Text "A"; Reasoning "B"; Text "C"; Reasoning "D"; Text "E"]
    ; "<think>unfinished</thi", [Reasoning "unfinished</thi"]
    ; "literal<thi", [Text "literal<thi"]
    ; "plain</think>reply", [Text "plain</think>reply"]
    ; "<think></think>reply", [Text "reply"]
    ]
  in
  List.for_all (fun (input, expected) ->
    let expected = test_typed_bytes expected in
    let len = String.length input in
    List.for_all (fun first ->
      List.for_all (fun second -> test_partition input [first; second] = expected)
        (List.init (len - first + 1) (fun i -> first + i)))
      (List.init (len + 1) Fun.id)) cases

let%test "one-byte fragments preserve UTF-8 bytes and flush only once" =
  let input = "앞<think>생각</think>뒤" in
  let expected = test_typed_bytes [Text "앞"; Reasoning "생각"; Text "뒤"] in
  let state = create () in
  let segments =
    List.init (String.length input) (fun i -> String.make 1 input.[i])
    |> List.concat_map (feed_segments state)
  in
  test_typed_bytes (segments @ flush_segments state) = expected
  && flush_segments state = []
