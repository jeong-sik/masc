module Store = Keeper_chat_store

type participant = {
  id : string;
  name : string option;
  authority : Store.speaker_authority;
  first_seen : float option;
  last_seen : float option;
  message_count : int;
  note : string option;
}

let default_limit = 20
let max_limit = 100

let opt_string_field key = function
  | Some value when String.trim value <> "" -> [ (key, `String value) ]
  | Some _ | None -> []

let opt_float_field key = function
  | Some value -> [ (key, `Float value) ]
  | None -> []

let message_json (m : Store.chat_message) : Yojson.Safe.t =
  let speaker_fields =
    match m.speaker with
    | None -> []
    | Some sp ->
        opt_string_field "speaker_id" sp.speaker_id
        @ opt_string_field "speaker_name" sp.speaker_name
        @ [
            ( "speaker_authority",
              `String (Store.authority_label sp.speaker_authority) );
          ]
  in
  (* Surface the writer-declared kind for non-utterance rows so the
     keeper reading its own lane sees a transport-failure marker as the
     server's record of a failed request, not as something it said. *)
  let kind_fields =
    match m.kind with
    | Store.Row_kind.Utterance -> []
    | Store.Row_kind.Transport_failure | Store.Row_kind.Agent_failure ->
        [ ("kind", `String (Store.Row_kind.to_label m.kind)) ]
  in
  `Assoc
    ([ ("role", `String (Store.Role.to_label m.role));
       ("content", `String m.content) ]
    @ kind_fields
    @ opt_float_field "ts" m.ts
    @ opt_string_field "source" m.source
    @ opt_string_field "conversation_id" m.conversation_id
    @ opt_string_field "external_message_id" m.external_message_id
    @ opt_string_field "tool_call_name" m.tool_call_name
    @ speaker_fields)

let participant_json (p : participant) : Yojson.Safe.t =
  `Assoc
    ([ ("id", `String p.id) ]
    @ opt_string_field "name" p.name
    @ [ ("authority", `String (Store.authority_label p.authority)) ]
    @ opt_float_field "first_seen" p.first_seen
    @ opt_float_field "last_seen" p.last_seen
    @ [ ("message_count", `Int p.message_count) ]
    @ opt_string_field "note" p.note)

(* Roster fold: one bucket per speaker_id over user lines. The most
   recent non-empty name wins (people rename; the log remembers, the
   roster reports the latest). *)
let roster (lane : Store.chat_message list) : participant list =
  let tbl : (string, participant) Hashtbl.t = Hashtbl.create 8 in
  List.iter
    (fun (m : Store.chat_message) ->
      match m.speaker with
      | Some { speaker_id = Some id; speaker_name; speaker_authority } ->
          let updated =
            match Hashtbl.find_opt tbl id with
            | None ->
                {
                  id;
                  name = speaker_name;
                  authority = speaker_authority;
                  first_seen = m.ts;
                  last_seen = m.ts;
                  message_count = 1;
                  note = None;
                }
            | Some p ->
                {
                  p with
                  name =
                    (match speaker_name with
                    | Some n when String.trim n <> "" -> Some n
                    | Some _ | None -> p.name);
                  last_seen = (match m.ts with Some _ -> m.ts | None -> p.last_seen);
                  first_seen =
                    (match (p.first_seen, m.ts) with
                    | None, ts -> ts
                    | some, _ -> some);
                  message_count = p.message_count + 1;
                }
          in
          Hashtbl.replace tbl id updated
      | Some { speaker_id = None; _ } | None -> ())
    lane;
  Hashtbl.fold (fun _id p acc -> p :: acc) tbl []
  |> List.sort (fun a b ->
         match (b.last_seen, a.last_seen) with
         | Some tb, Some ta -> compare tb ta
         | Some _, None -> 1
         | None, Some _ -> -1
         | None, None -> compare a.id b.id)

let take_last n items =
  let len = List.length items in
  if len <= n then items
  else
    let rec drop k = function
      | rest when k <= 0 -> rest
      | [] -> []
      | _ :: rest -> drop (k - 1) rest
    in
    drop (len - n) items

(* Oldest ts across the whole loaded page (not just the lane filter):
   passing it back as the next [before] guarantees walk progress even
   when a page holds no rows for the requested lane (RFC-0228 P1). *)
let page_oldest_ts (messages : Store.chat_message list) : float option =
  List.fold_left
    (fun acc (m : Store.chat_message) ->
      match (acc, m.ts) with
      | None, ts -> ts
      | Some a, Some t when t < a -> Some t
      | some, _ -> some)
    None messages

(* RFC-0229 P1: notes are keeper-scoped deliberate memory. Union them
   into the roster — annotating people still present, and resurrecting
   noted people whose chat rows aged out of the window (note-only
   entries: no sightings, zero message_count, External authority since
   ids come from connector rosters). *)
let with_notes (notes : (string * string) list) (roster : participant list) :
    participant list =
  let annotated =
    List.map
      (fun p ->
        match List.assoc_opt p.id notes with
        | Some n when String.trim n <> "" -> { p with note = Some n }
        | Some _ | None -> p)
      roster
  in
  let known = List.map (fun p -> p.id) annotated in
  let note_only =
    List.filter_map
      (fun (id, n) ->
        if String.trim n = "" || List.mem id known then None
        else
          Some
            {
              id;
              name = None;
              authority = Store.External;
              first_seen = None;
              last_seen = None;
              message_count = 0;
              note = Some n;
            })
      notes
  in
  annotated @ note_only

let respond ~surface ~limit ~has_more ~notes
    (messages : Store.chat_message list) : string =
  let surface = String.trim surface in
  if surface = "" then
    Yojson.Safe.to_string
      (`Assoc
        [
          ( "error",
            `String
              "surface is required. Use a lane label shown in Connected \
               Surfaces or chat history; this tool reads that connected lane, \
               not a connector-wide channel registry."
          );
        ])
  else
    let limit = min max_limit (max 1 limit) in
    let lane =
      List.filter
        (fun (m : Store.chat_message) ->
          match m.source with
          | Some s -> String.equal (String.trim s) surface
          | None -> false)
        messages
    in
    let shown = take_last limit lane in
    Yojson.Safe.to_string
      (`Assoc
        ([
           ("surface", `String surface);
           ("messages", `List (List.map message_json shown));
           ( "participants",
            `List (List.map participant_json (with_notes notes (roster lane)))
          );
           ("lane_row_count", `Int (List.length lane));
           ("returned", `Int (List.length shown));
           ("has_more", `Bool has_more);
         ]
        @ opt_float_field "oldest_ts" (page_oldest_ts messages)))
