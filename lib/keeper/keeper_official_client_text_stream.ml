type 'message t =
  { equal : 'message -> 'message -> bool
  ; shown : Buffer.t (* every delta forwarded this turn, breaks included *)
  ; current : Buffer.t (* the text of the message streaming now *)
  ; mutable message : 'message option
        (* that message's identity, once the wire named it *)
  ; mutable after_tool_row : bool
        (* a tool row was forwarded since the last non-empty piece *)
  }

let create ~equal () =
  { equal
  ; shown = Buffer.create 256
  ; current = Buffer.create 256
  ; message = None
  ; after_tool_row = false
  }
;;

let paragraph_break = "\n\n"

(* A new message needs text already streaming and two identities the wire
   named that differ. A piece without an identity cannot tell, so it
   continues the message in front of it. *)
let starts_new_message t ~message =
  Buffer.length t.current > 0
  &&
  match t.message, message with
  | Some streaming, Some incoming -> not (t.equal streaming incoming)
  | Some _, None | None, Some _ | None, None -> false
;;

(* The newlines that complete a paragraph break after what was shown.
   Antigravity ends each response step with its own "\n", so that stream
   needs one more; a stream already ending in a blank line needs none. *)
let break_after shown =
  let length = Buffer.length shown in
  let newline_at i = i >= 0 && Char.equal (Buffer.nth shown i) '\n' in
  if newline_at (length - 1) && newline_at (length - 2) then ""
  else if newline_at (length - 1) then "\n"
  else paragraph_break
;;

let forward t ~message piece =
  if String.equal piece ""
  then piece
  else (
    let delta =
      if starts_new_message t ~message
      then (
        Buffer.clear t.current;
        if t.after_tool_row then piece else break_after t.shown ^ piece)
      else piece
    in
    (match message with
     | Some _ -> t.message <- message
     | None -> ());
    Buffer.add_string t.current piece;
    Buffer.add_string t.shown delta;
    t.after_tool_row <- false;
    delta)
;;

let tool_row t = t.after_tool_row <- true

let suffix_after ~prefix text =
  let prefix_length = String.length prefix in
  if String.starts_with ~prefix text && String.length text > prefix_length
  then Some (String.sub text prefix_length (String.length text - prefix_length))
  else None
;;

let remainder t ~final_text =
  let shown = Buffer.contents t.shown in
  if String.starts_with ~prefix:shown final_text
  then suffix_after ~prefix:shown final_text
  else suffix_after ~prefix:(Buffer.contents t.current) final_text
;;
