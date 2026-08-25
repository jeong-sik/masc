type activity =
  | Working
  | Connection of Masc_tui_types.connection_status

type snapshot =
  { activity : activity
  ; keeper_name : string option
  ; runtime_id : string option
  ; workspace : string
  }

let make ~activity ~keeper_name ~runtime_id ~workspace =
  { activity; keeper_name; runtime_id; workspace }
;;

let maximum_scalars = 240
let maximum_examined_scalars = maximum_scalars * 4

let is_bidi_control code =
  code = 0x061C
  || code = 0x200E
  || code = 0x200F
  || (code >= 0x202A && code <= 0x202E)
  || (code >= 0x2066 && code <= 0x206F)
;;

let is_space code =
  (code >= 0x09 && code <= 0x0D)
  || code = 0x20
  || code = 0x85
  || code = 0xA0
  || code = 0x1680
  || (code >= 0x2000 && code <= 0x200A)
  || code = 0x2028
  || code = 0x2029
  || code = 0x202F
  || code = 0x205F
  || code = 0x3000
;;

let is_control code = code < 0x20 || (code >= 0x7F && code <= 0x9F)

(* OSC payloads are not ordinary screen text: escaping an ESC as [\x1B]
   would be safe, but it would also put the attack-shaped bytes in the tab.
   Drop controls and bidi formatting instead, and collapse every logical line
   separator to one space so a title remains one line in every terminal. *)
let sanitize text =
  let output = Buffer.create maximum_scalars in
  let pending_space = ref false in
  let output_count = ref 0 in
  let append_space () =
    if !output_count > 0 then pending_space := true
  in
  let append_scalar scalar =
    let needed = if !pending_space then 2 else 1 in
    if !output_count + needed <= maximum_scalars then begin
      if !pending_space then Buffer.add_char output ' ';
      pending_space := false;
      Buffer.add_utf_8_uchar output scalar;
      output_count := !output_count + needed
    end
  in
  let rec loop offset examined =
    if
      offset < String.length text
      && examined < maximum_examined_scalars
      && !output_count < maximum_scalars
    then begin
      let decoded = String.get_utf_8_uchar text offset in
      let length = max 1 (Uchar.utf_decode_length decoded) in
      if Uchar.utf_decode_is_valid decoded then begin
        let scalar = Uchar.utf_decode_uchar decoded in
        let code = Uchar.to_int scalar in
        if is_space code then append_space ()
        else if is_control code || is_bidi_control code then ()
        else append_scalar scalar
      end;
      loop (offset + length) (examined + 1)
    end
  in
  loop 0 0;
  Buffer.contents output
;;

let truncate_scalars text =
  let output = Buffer.create (min (String.length text) maximum_scalars) in
  let rec loop offset count =
    if offset < String.length text && count < maximum_scalars then begin
      let decoded = String.get_utf_8_uchar text offset in
      let length = max 1 (Uchar.utf_decode_length decoded) in
      if Uchar.utf_decode_is_valid decoded then begin
        Buffer.add_utf_8_uchar output (Uchar.utf_decode_uchar decoded);
        loop (offset + length) (count + 1)
      end else loop (offset + length) count
    end
  in
  loop 0 0;
  Buffer.contents output
;;

let nonblank value =
  let value = sanitize value in
  if String.equal value "" then None else Some value
;;

let activity_text = function
  | Working -> "working"
  | Connection status -> Masc_tui_types.connection_status_label status
;;

let select_keeper ~live ~inflight ~visible =
  match live with
  | Some _ as live -> live
  | None ->
      (match visible with
       | Some visible when List.exists (String.equal visible) inflight ->
           Some visible
       | Some _ | None ->
           (match inflight with
            | first :: _ -> Some first
            | [] -> visible))
;;

let text snapshot =
  let keeper = Option.bind snapshot.keeper_name nonblank in
  let runtime = Option.bind snapshot.runtime_id nonblank in
  let identity =
    match keeper, runtime with
    | Some keeper, Some runtime -> Some (keeper ^ "/" ^ runtime)
    | Some keeper, None -> Some keeper
    | None, Some runtime -> Some runtime
    | None, None -> None
  in
  let workspace = Option.value ~default:"MASC" (nonblank snapshot.workspace) in
  activity_text snapshot.activity :: Option.to_list identity @ [ workspace ]
  |> String.concat " \xc2\xb7 "
  |> truncate_scalars
;;

type t =
  { mutable last : string option
  ; mutable may_be_set : bool
  }

let create () = { last = None; may_be_set = false }
let osc payload = "\027]0;" ^ payload ^ "\007"

let present state ~write ~flush snapshot =
  let next = text snapshot in
  if state.last <> Some next then begin
    (* Set before I/O: a writer can put every byte in the kernel and only its
       flush can fail. Cleanup must still try to clear that possible title. *)
    state.may_be_set <- true;
    try
      write (osc next);
      flush ();
      state.last <- Some next
    with _ -> state.last <- None
  end
;;

let clear state ~write ~flush =
  if state.may_be_set then begin
    state.last <- None;
    try
      write (osc "");
      flush ();
      state.may_be_set <- false
    with _ -> ()
  end
;;
