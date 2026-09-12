(** Ephemeral activity for the running Keeper turn. Reset at turn entry;
    the turns route also rejects observations older than its running turn.
    Provider attempts, stream events, and tool hooks write this projection. *)

type activity = Preparing | Awaiting_response | Receiving_response | Failed

type t =
  { text_tail : string
  ; current_tool : string option
  ; updated_at : float
  ; runtime_id : string option
  ; activity : activity
  ; last_failure : string option
  }

(* Enough to recognize the work ("ah, it is writing the PR body"), small
   enough that the turns poll stays a light projection. *)
let tail_bytes = 240

let table : (string, t) Hashtbl.t = Hashtbl.create 16

(* Last [max_bytes] of [s], starting on a UTF-8 boundary so a cut Hangul
   glyph never reaches a terminal. Walking forward from the byte cut skips
   continuation bytes (0b10xxxxxx) only — at most 3 steps. *)
let utf8_tail ~max_bytes s =
  let len = String.length s in
  if len <= max_bytes then s
  else begin
    let start = ref (len - max_bytes) in
    while
      !start < len && Char.code s.[!start] land 0xC0 = 0x80
    do
      incr start
    done;
    String.sub s !start (len - !start)
  end
;;

let mutex = Mutex.create ()

let with_lock f =
  Mutex.lock mutex;
  Fun.protect ~finally:(fun () -> Mutex.unlock mutex) f

let empty now =
  { text_tail = ""; current_tool = None; updated_at = now
  ; runtime_id = None; activity = Preparing; last_failure = None }

let current ~keeper_name =
  with_lock (fun () -> Hashtbl.find_opt table keeper_name)

let update ~keeper_name ~now f =
  with_lock (fun () ->
    let old = Option.value ~default:(empty now) (Hashtbl.find_opt table keeper_name) in
    Hashtbl.replace table keeper_name { (f old) with updated_at = now })

let reset ~keeper_name ~now = update ~keeper_name ~now (fun _ -> empty now)

let note_attempt ~keeper_name ~now ~runtime_id =
  update ~keeper_name ~now (fun old ->
    { old with runtime_id = Some runtime_id; activity = Awaiting_response
    ; current_tool = None; text_tail = "" })

let note_failure ~keeper_name ~now ~runtime_id detail =
  update ~keeper_name ~now (fun old ->
    { old with runtime_id = Some runtime_id; activity = Failed
    ; current_tool = None; last_failure = Some detail })

let note_text ~keeper_name ~now text =
  let text = String.trim text in
  if not (String.equal text "") then
    update ~keeper_name ~now (fun old ->
      { old with text_tail = utf8_tail ~max_bytes:tail_bytes text
      ; activity = Receiving_response })

let note_tool ~keeper_name ~now current_tool =
  update ~keeper_name ~now (fun old -> { old with current_tool })

let note_stream ~keeper_name ~now event =
  match event with
  | Agent_core.Types.ContentBlockDelta { delta = TextDelta text; _ } ->
    update ~keeper_name ~now (fun old ->
      { old with text_tail = utf8_tail ~max_bytes:tail_bytes (old.text_tail ^ text)
      ; activity = Receiving_response })
  | ContentBlockDelta { delta = TextSnapshot text; _ } ->
    note_text ~keeper_name ~now text
  | MessageStart _ | ContentBlockDelta { delta = ThinkingDelta _ | ReasoningDetailsDelta _; _ } ->
    update ~keeper_name ~now (fun old -> { old with activity = Receiving_response })
  | _ -> ()

let status_text preview =
  let activity =
    match preview.current_tool, preview.activity with
    | Some tool, _ -> "tool running: " ^ tool
    | None, Preparing -> "preparing turn"
    | None, Awaiting_response -> "waiting for provider response"
    | None, Receiving_response -> "receiving response"
    | None, Failed -> "provider attempt failed"
  in
  String.concat " · "
    (List.filter_map Fun.id
       [ preview.runtime_id; Some activity
       ; Option.map (fun detail -> "last failure: " ^ detail) preview.last_failure ])
