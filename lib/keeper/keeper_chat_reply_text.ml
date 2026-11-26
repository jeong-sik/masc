type t =
  { text : string
  ; response : Keeper_chat_events.text_response option
        (* The response of the last appended non-empty delta. [None] before
           the first delta and after [of_string]. *)
  ; visible : bool  (* [text] holds a non-whitespace character. *)
  ; break_pending : bool
        (* A new response began after visible text. Its first visible delta
           starts a paragraph; whitespace before that waits in [text]. *)
  }

let is_space = function
  | ' ' | '\t' | '\n' | '\r' -> true
  | _ -> false

let has_visible text = String.exists (fun c -> not (is_space c)) text

let empty = { text = ""; response = None; visible = false; break_pending = false }

let of_string text =
  { text; response = None; visible = has_visible text; break_pending = false }

let same_response (a : Keeper_chat_events.text_response)
    (b : Keeper_chat_events.text_response) =
  match a, b with
  | Keeper_chat_events.Observed_response a, Keeper_chat_events.Observed_response b ->
      Int.equal a.response_generation b.response_generation
      && Int.equal a.response_scope b.response_scope
  | Keeper_chat_events.Unobserved_scope a, Keeper_chat_events.Unobserved_scope b ->
      Option.equal Int.equal a b
  | Keeper_chat_events.Observed_response _, Keeper_chat_events.Unobserved_scope _
  | Keeper_chat_events.Unobserved_scope _, Keeper_chat_events.Observed_response _ ->
      false

let blank_line = "\n\n"

(* The newlines [text] still needs to end in a blank line. Newlines the model
   already wrote count toward it, so a message ending in "\n" gets one more
   and one ending in "\n\n" gets none. *)
let paragraph_break_after text =
  let len = String.length text in
  if len >= 2 && text.[len - 1] = '\n' && text.[len - 2] = '\n' then ""
  else if len >= 1 && text.[len - 1] = '\n' then "\n"
  else blank_line

let append t ~response delta =
  if String.equal delta "" then t
  else
    let starts_response =
      match t.response with
      | None -> true
      | Some previous -> not (same_response previous response)
    in
    let break_pending = t.break_pending || (starts_response && t.visible) in
    let delta_visible = has_visible delta in
    if break_pending && delta_visible then
      { text = t.text ^ paragraph_break_after t.text ^ delta
      ; response = Some response
      ; visible = true
      ; break_pending = false
      }
    else
      { text = t.text ^ delta
      ; response = Some response
      ; visible = t.visible || delta_visible
      ; break_pending
      }

let to_string t = t.text
