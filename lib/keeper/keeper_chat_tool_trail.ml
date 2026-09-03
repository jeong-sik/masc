(* See keeper_chat_tool_trail.mli for why a connector renders a turn's tools as
   one block instead of a message per call. *)

let subject_max_bytes = 72
(* A channel delivers the trail on the same message as the reply, and the reply
   is the part the reader asked for. *)
let default_max_rows = 8

(* Past this the padding costs more room than the alignment buys: a name like
   masc_keeper_delegate_status would indent every other row behind it. *)
let name_pad_max = 16

type call =
  { name : string
  ; mutable args : string
  }

module Occurrence = struct
  type t = int * int
  let equal (left_scope, left_index) (right_scope, right_index) =
    left_scope = right_scope && left_index = right_index
  let hash = Hashtbl.hash
end

module Occurrence_table = Hashtbl.Make (Occurrence)

type t =
  { by_occurrence : call Occurrence_table.t
  ; mutable rev_order : call list
  }

let create () = { by_occurrence = Occurrence_table.create 8; rev_order = [] }

let occurrence_key (occurrence : Keeper_chat_events.tool_stream_occurrence) =
  occurrence.stream_scope, occurrence.block_index
;;

let on_event t (event : Keeper_chat_events.keeper_chat_event) =
  match event with
  | Tool_call_start { occurrence; tool_call_name; _ } ->
    let key = occurrence_key occurrence in
    if not (Occurrence_table.mem t.by_occurrence key)
    then begin
      let call = { name = tool_call_name; args = "" } in
      Occurrence_table.replace t.by_occurrence key call;
      t.rev_order <- call :: t.rev_order
    end
  | Tool_call_args { occurrence; delta; _ } ->
    (match Occurrence_table.find_opt t.by_occurrence (occurrence_key occurrence) with
     | None -> ()
     | Some call -> call.args <- call.args ^ delta)
  | Tool_call_args_snapshot { occurrence; snapshot; _ } ->
    (match Occurrence_table.find_opt t.by_occurrence (occurrence_key occurrence) with
     | None -> ()
     | Some call -> call.args <- snapshot)
  | _ ->
    (* Every other chat event belongs to the reply the adapter is already
       delivering; this collector only holds the trail beside it. *)
    ()
;;

let calls t = List.rev t.rev_order
let call_count t = List.length t.rev_order

(* --- Subject: the one argument a reader identifies a call by --------------- *)

(* Ordered, not keyed by tool name: the same key means the same thing across
   tools, and a name table would need an entry per tool. Mirrors SUBJECT_KEYS in
   dashboard/src/components/tool-call-shared.ts. *)
let subject_keys =
  [ "argv" (* Execute: the command that ran, without a shell *)
  ; "script" (* Execute: the command line a shell ran *)
  ; "command"
  ; "cmd"
  ; "file_path" (* Read / Edit / Write *)
  ; "pattern" (* Grep: what it looked for, before where it looked *)
  ; "path"
  ; "query"
  ; "url"
  ; "target"
  ; "task_id"
  ; "goal_id"
  ; "agent_name" (* MASC agent/keeper tools: whose record was read *)
  ; "keeper_name"
  ; "post_id"
  ; "operation_id"
  ; "sha256"
  ; "title"
  ; "action"
  ; "status"
  ; "content"
  ]
;;

let rec value_text (json : Yojson.Safe.t) =
  match json with
  | `String s ->
    let s = String.trim s in
    if s = "" then None else Some s
  | `Int i -> Some (string_of_int i)
  | `Intlit s -> Some s
  | `Float f -> Some (Printf.sprintf "%g" f)
  | `Bool b -> Some (string_of_bool b)
  | `List items ->
    (* argv: show it the way it was run, not as JSON. *)
    (match List.filter_map value_text items with
     | [] -> None
     | parts -> Some (String.concat " " parts))
  | `Assoc _ as assoc ->
    let s = Yojson.Safe.to_string assoc in
    if String.equal s "{}" then None else Some s
  | `Null -> None
;;

let collapse_whitespace s =
  let buf = Buffer.create (String.length s) in
  let pending_space = ref false in
  String.iter
    (fun c ->
      match c with
      | ' ' | '\t' | '\n' | '\r' -> if Buffer.length buf > 0 then pending_space := true
      | c ->
        if !pending_space
        then begin
          Buffer.add_char buf ' ';
          pending_space := false
        end;
        Buffer.add_char buf c)
    s;
  Buffer.contents buf
;;

(* A path is identified by its tail as much as its head, and '/' is always a
   UTF-8 boundary, so segments are the safe cut points. *)
let keep_path_tail s =
  let segments = List.rev (String.split_on_char '/' s) in
  let rec take kept len = function
    | [] -> kept
    | segment :: rest ->
      let len' = len + String.length segment + 1 in
      if len' > subject_max_bytes then kept else take (segment :: kept) len' rest
  in
  match take [] 1 segments with
  | [] -> None
  | kept -> Some ("…/" ^ String.concat "/" kept)
;;

let shorten s =
  let flat = collapse_whitespace s in
  if String.length flat <= subject_max_bytes
  then flat
  else (
    match if String.contains flat '/' then keep_path_tail flat else None with
    | Some tail -> tail
    | None ->
      let head, _truncated =
        Keeper_text_processing.truncate_utf8_prefix ~max_bytes:(subject_max_bytes - 3) flat
      in
      head ^ "…")
;;

(* The keys above are a preference, not a gate. They name the argument that
   identifies a call best when the shape is known; when none of them is
   present, the whole argument object is still a better answer than nothing.

   It used to return [None] there, and [render_rows] drew the bare tool name.
   On one live keeper that was three of six calls: [keeper_tasks_audit
   {"limit":20}], [masc_agent_timeline {"agent_name":…,"limit":5,…}] and
   [masc_agent_card {}] all scrolled back as a name with no argument, so a turn
   that read a specific agent's timeline looked the same as one that read
   anything else. An empty object is the one case that legitimately says
   nothing, and [value_text] already answers [None] for it. *)
(* Objects whose own subject is one level down. [keeper_skill] takes an
   [identity] of {source_id, package_id, name}, and the whole-object fallback
   below spends the 72-cell budget on the envelope: the [name] value starts
   around byte 75 and is never reached, so two skills from one source read
   alike. Descending one level names the skill instead.

   Keys, not tool names, like the list above -- and the same shape
   [Tool_input_path.nested_object_keys] already uses for the same job. *)
let nested_subject_keys = [ "identity"; "reference"; "arguments"; "args" ]

(* Inside one of those, [name] is the subject. It is deliberately not in
   [subject_keys] above: seventeen tools declare a top-level [name] parameter
   and promoting it there would rename their rows too. One level down, inside
   an identity, the word means the one thing. *)
let nested_first_keys = [ "name" ]

let subject_of_assoc fields =
  let direct =
    List.find_map
      (fun key -> Option.bind (List.assoc_opt key fields) value_text)
      subject_keys
  in
  let nested () =
    List.find_map
      (fun key ->
        match List.assoc_opt key fields with
        | Some (`Assoc inner) ->
          List.find_map
            (fun inner_key ->
              Option.bind (List.assoc_opt inner_key inner) value_text)
            (nested_first_keys @ subject_keys)
        | Some _ | None -> None)
      nested_subject_keys
  in
  match (match direct with Some _ as found -> found | None -> nested ()) with
  | Some subject -> Some (shorten subject)
  | None ->
    (* Fields that carry no text are dropped first, so a blank value cannot
       become a name by riding along inside the object: [{"file_path":"   "}]
       still names nothing, the way it did when the key matched. *)
    (match
       List.filter (fun (_, value) -> Option.is_some (value_text value)) fields
     with
     | [] -> None
     | named -> Option.map shorten (value_text (`Assoc named)))
;;

(* What a result says, when it says it in a shape this workspace writes.

   Tool results share an envelope -- [ok] plus a payload -- and the payload's
   name is what differs: [error] when the call failed, [output] for a command,
   [content] for a read, [path] and [bytes_written] for a write. Measured on
   one keeper's newest hundred calls: 63 carried [output], 17 were not JSON at
   all, and the rest split across the others.

   [error] comes first because a call that failed says why before it says
   anything else. Like {!subject_keys} this is a preference and not a gate:
   a shape with none of these keys is still better named by its own text than
   by nothing, and the whole-object fallback below is what says it.

   The caller gets one short line. Callers that want the whole result read it
   from the surface that serves it; this is the line that goes in a row. *)
let result_keys = [ "error"; "output"; "content"; "path"; "detail"; "message" ]

let tool_result_digest ~result =
  let trimmed = String.trim result in
  if String.equal trimmed "" then None
  else (
    match Yojson.Safe.from_string trimmed with
    | `Assoc fields ->
      (match
         List.find_map
           (fun key -> Option.bind (List.assoc_opt key fields) value_text)
           result_keys
       with
       | Some text -> Some (shorten text)
       | None -> subject_of_assoc fields)
    | `String _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `List _ | `Null ->
      value_text (Yojson.Safe.from_string trimmed) |> Option.map shorten
    | exception Yojson.Json_error _ ->
      (* Seventeen of that hundred were plain text, not JSON. The text is the
         result; it needs shortening, not parsing. *)
      Some (shorten trimmed))
;;

let tool_subject ~name:_ ~args =
  let trimmed = String.trim args in
  if String.equal trimmed ""
  then None
  else (
    match Yojson.Safe.from_string trimmed with
    | `Assoc fields -> subject_of_assoc fields
    | `String _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `List _ | `Null ->
      (* A tool whose whole argument is one scalar or array has no key to pick,
         so the argument is its own subject. Spelled out rather than left to a
         catch-all: a new Yojson variant should stop the build, not silently
         land here. *)
      Some (shorten trimmed)
    | exception Yojson.Json_error _ ->
      (* Arguments still streaming in, or a provider that does not send JSON.
         The fragment names the call better than nothing does. *)
      Some (shorten trimmed))
;;

(* --- Rendering ------------------------------------------------------------ *)

let pad_to width s =
  let len = String.length s in
  if len >= width then s else s ^ String.make (width - len) ' '
;;

let render ?(max_rows = default_max_rows) t =
  match calls t with
  | [] -> None
  | all ->
    let total = List.length all in
    let shown = if total <= max_rows then all else List.filteri (fun i _ -> i < max_rows) all in
    let hidden = total - List.length shown in
    let name_width =
      List.fold_left (fun acc call -> max acc (String.length call.name)) 0 shown
      |> min name_pad_max
    in
    let last_row = List.length shown - 1 in
    let row index call =
      let branch = if index = last_row && hidden = 0 then "└" else "├" in
      match tool_subject ~name:call.name ~args:call.args with
      | None -> Printf.sprintf "%s %s" branch call.name
      | Some subject ->
        Printf.sprintf
          "%s %s %s"
          branch
          (pad_to name_width call.name)
          (Observability_redact.redact_text subject)
    in
    let rows = List.mapi row shown in
    let rows = if hidden > 0 then rows @ [ Printf.sprintf "└ 그 외 %d개" hidden ] else rows in
    Some (String.concat "\n" rows)
;;

let append_to ?max_rows t ~text =
  if String.length text = 0
  then text
  else (
    match render ?max_rows t with
    | None -> text
    | Some rows -> Printf.sprintf "%s\n```\n%s\n```" text rows)
;;

