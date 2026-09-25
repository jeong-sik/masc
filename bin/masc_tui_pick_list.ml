type t =
  { cursor : int
  ; query : string option
  }

let closed = { cursor = 0; query = None }

type step =
  | Prev
  | Next
  | Page_prev
  | Page_next
  | First
  | Last

type action =
  | Move of step
  | Open_query
  | Type of string
  | Erase
  | Back
  | Choose

(* The row search calls this once per row per keystroke, so on a
   twenty-thousand-line file a copying lowercase would ask the allocator for
   the file again and then for a slice per character of it. Folding case per
   byte the way [String.lowercase_ascii] does -- ASCII A-Z and nothing else,
   so a UTF-8 continuation byte is left alone -- keeps the same answers
   without the copies. *)
let lowercase_byte c =
  if c >= 'A' && c <= 'Z' then Char.unsafe_chr (Char.code c + 32) else c

let lowercase_contains ~needle haystack =
  let n = String.length needle and h = String.length haystack in
  if n = 0 then true
  else if n > h then false
  else
    let rec matches_at i k =
      k >= n
      || Char.equal
           (lowercase_byte (String.unsafe_get haystack (i + k)))
           (lowercase_byte (String.unsafe_get needle k))
         && matches_at i (k + 1)
    in
    let rec at i = i + n <= h && (matches_at i 0 || at (i + 1)) in
    at 0

(* Keys are strings on the wire, so the last arm is the answer for every key
   this list does not bind: [None], which the caller reads as "not mine" and
   passes on. The bound keys are all spelled above it. *)
let action_of_key ~close_keys t key =
  match t.query with
  | Some _ -> (
      match key with
      | "up" | "wheel-up" -> Some (Move Prev)
      | "down" | "wheel-down" -> Some (Move Next)
      | "pageup" -> Some (Move Page_prev)
      | "pagedown" -> Some (Move Page_next)
      | "home" -> Some (Move First)
      | "end" -> Some (Move Last)
      | "esc" -> Some Back
      | "\r" | "\n" | "enter" -> Some Choose
      | "\127" | "\b" | "backspace" -> Some Erase
      | typed when Masc_tui_message_layout.is_printable_utf8_scalar typed ->
          Some (Type typed)
      | _unbound -> None)
  | None -> (
      match key with
      | "up" | "k" | "wheel-up" -> Some (Move Prev)
      | "down" | "j" | "wheel-down" -> Some (Move Next)
      | "pageup" -> Some (Move Page_prev)
      | "pagedown" -> Some (Move Page_next)
      | "home" -> Some (Move First)
      | "end" -> Some (Move Last)
      | "/" -> Some Open_query
      | "esc" -> Some Back
      | "\r" | "\n" | "enter" -> Some Choose
      | close when List.exists (String.equal close) close_keys -> Some Back
      | _unbound -> None)

type 'a outcome =
  | Stay of t
  | Chosen of 'a
  | Dismissed

(* The items the filter keeps, each with its position in the whole list. The
   match reads the label the picker draws, so what the operator sees is what
   the query is matched against. *)
let narrowed ~label query items =
  let indexed = List.mapi (fun index item -> (index, item)) items in
  match query with
  | None -> indexed
  | Some needle ->
      List.filter (fun (_, item) -> lowercase_contains ~needle (label item)) indexed

(* A new query starts from the first match, the way the command palette
   does: the row that was under the cursor may not be in the list any
   more. *)
let requeried query = { cursor = 0; query = Some query }

let type_text t text = requeried (Option.value t.query ~default:"" ^ text)

let clamp ~count cursor = Masc_tui_scroll.cursor_move ~count ~delta:0 cursor

let apply ~page ~label items t action =
  let page = max 1 page in
  let kept = narrowed ~label t.query items in
  let count = List.length kept in
  let cursor = clamp ~count t.cursor in
  match action with
  | Move step ->
      let target =
        match step with
        | Prev -> cursor - 1
        | Next -> cursor + 1
        | Page_prev -> cursor - page
        | Page_next -> cursor + page
        | First -> 0
        | Last -> Masc_tui_scroll.cursor_last ~count
      in
      Stay { t with cursor = clamp ~count target }
  | Open_query -> (
      match t.query with
      | Some _ -> Stay { t with cursor }
      | None -> Stay { cursor; query = Some "" })
  | Type typed -> Stay (type_text t typed)
  | Erase -> (
      match t.query with
      (* Nothing to erase: the list and the cursor stay where they are. *)
      | None -> Stay { t with cursor }
      | Some query when String.length query = 0 -> Stay { t with cursor }
      | Some query ->
          Stay (requeried (Masc_tui_message_layout.drop_last_utf8_scalar query)))
  | Back -> (
      match t.query with
      | None -> Dismissed
      | Some _ ->
          (* Dropping the filter keeps the item the cursor was on: it goes
             back to that item's place in the whole list. *)
          let whole =
            match List.nth_opt kept cursor with
            | Some (index, _) -> index
            | None -> 0 (* nothing matched: the whole list opens at its head *)
          in
          Stay { cursor = whole; query = None })
  | Choose -> (
      match List.nth_opt kept cursor with
      | Some (_, item) -> Chosen item
      | None -> Stay { t with cursor })

type 'a view =
  { rows : 'a list
  ; selected_row : int option
  ; shown : int
  ; total : int
  ; filter : string option
  }

let view ~page ~label items t =
  let page = max 1 page in
  let kept = List.map snd (narrowed ~label t.query items) in
  let shown = List.length kept in
  let cursor = clamp ~count:shown t.cursor in
  (* The window opens at the cursor and stops a page short of the end, so
     the last page is always full and the cursor is always inside it. *)
  let top = max 0 (min cursor (shown - page)) in
  let rows = List.filteri (fun index _ -> index >= top && index < top + page) kept in
  { rows
  ; selected_row = (if shown = 0 then None else Some (cursor - top))
  ; shown
  ; total = List.length items
  ; filter = t.query
  }

let summary v =
  match v.filter with
  | None -> Printf.sprintf "%d of %d \xc2\xb7 / filter" v.shown v.total
  | Some query -> Printf.sprintf "filter: %s\xe2\x96\x8f %d of %d" query v.shown v.total
