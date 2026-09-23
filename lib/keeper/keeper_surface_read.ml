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
    | Store.Row_kind.Transport_failure ->
        [ ("kind", `String (Store.Row_kind.to_label m.kind)) ]
  in
  `Assoc
    ([ ("role", `String (Store.Role.to_label m.role));
       ("content", `String m.content) ]
    @ kind_fields
    @ [ ("ts", `Float m.ts) ]
    @ opt_string_field "source" (Option.map Surface_ref.lane_label m.surface)
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
                  first_seen = Some m.ts;
                  last_seen = Some m.ts;
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
                  last_seen = Some m.ts;
                  first_seen =
                    (match p.first_seen with
                    | None -> Some m.ts
                    | Some _ as seen -> seen);
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
      match acc with
      | None -> Some m.ts
      | Some oldest -> Some (Float.min oldest m.ts))
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

(* --- Unbound / unknown labels are not an empty lane (task-1596). ---
   [respond] used to answer any non-blank label with a successful
   zero-row page, so "slack" with no bound channel and "salc" (typo)
   were byte-identical to a quiet connected lane — a silent data hole.
   Post's doctrine already covers the write side ("posting to an
   unbound surface is an error, not a no-op"); the read side now gets
   the same binding knowledge, optionally: the knowledge belongs to the
   runtime, so pure callers (tests, REST reuse) keep the unverified
   behaviour. [connector_bindings] carries the keeper's bound channel
   lists for the two connector lanes whose bindings the runtime can
   prove; gate channels (calendar etc.) have no registry to consult,
   so a gate label is only accepted when it actually appears on this
   page — and a gate label with zero rows anywhere honest about it. *)

type connector_bindings = { slack : string list; discord : string list }

type binding_verdict =
  | Unbound_connector
  | Unknown_label of string list  (* distinct labels present on this page *)

let error_json message =
  Yojson.Safe.to_string (`Assoc [ ("error", `String message) ])

(* Exactly the labels this page carries, in the exact-trimmed form the
   lane filter compares — the hint must name labels that would really
   have matched. *)
let page_labels (messages : Store.chat_message list) : string list =
  messages
  |> List.filter_map (fun (m : Store.chat_message) ->
         match m.surface with
         | Some s -> Some (Surface_ref.lane_label s |> String.trim)
         | None -> None)
  |> List.sort_uniq String.compare

let unbound_connector_hint (b : connector_bindings) =
  let fmt = function [] -> "none" | chans -> String.concat ", " chans in
  Printf.sprintf
    "this keeper has no bound channels there (slack: [%s]; discord: [%s]); \
     a channel becomes connected after its first inbound event — read a \
     connected lane instead"
    (fmt b.slack) (fmt b.discord)

let unknown_label_hint = function
  | [] ->
      "no lane rows on this page carry any surface label; pass surface \
       exactly as a lane label shown in Connected Surfaces or chat history"
  | labels ->
      Printf.sprintf
        "no lane rows carry this label; labels present on this page: %s — \
         pass surface exactly as shown in Connected Surfaces or chat history"
        (String.concat ", " labels)

(* Core lanes exist for every keeper, so they never read as "unknown";
   slack/discord are unbound only when the runtime's binding lists say
   so. Any other label is a gate channel label, and without a registry
   the page itself is the only evidence: present -> a legitimate lane,
   absent -> unknown. The page is the newest window, so an absence proves
   nothing while older rows remain ([has_more]): a gate lane that went quiet
   behind the window reads as an empty page whose cursor pages back to it.
   Same trimmed-exact comparison as the filter. *)
let classify_surface ~bindings ~has_more ~(page_labels : string list) surface =
  let surface = String.trim surface in
  match surface with
  | "dashboard" | "agent" | "broadcast" | "webhook" -> None
  | "slack" ->
      if bindings.slack = [] then Some Unbound_connector else None
  | "discord" ->
      if bindings.discord = [] then Some Unbound_connector else None
  | _ ->
      if List.mem surface page_labels || has_more then None
      else Some (Unknown_label page_labels)

let respond_unverified ~surface ~limit ~has_more ~notes
    (messages : Store.chat_message list) : string =
  (* Non-blank [surface] assumed — the blank rejection lives in
     [respond], which routes here when nothing can be proven wrong. *)
  let limit = min max_limit (max 1 limit) in
    let lane =
      List.filter
        (fun (m : Store.chat_message) ->
          match m.surface with
          | Some typed_surface ->
              String.equal
                (Surface_ref.lane_label typed_surface |> String.trim)
                surface
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

(* The tool entry: blank surface stays an error, then — only when the
   runtime supplied binding knowledge — a label that can be proven
   wrong is refused with the post-shaped error JSON instead of a
   silent zero-row page. Without [bindings] the projection is exactly
   the pure one the tests and REST reuse already pin down. *)
let respond ?bindings ~surface ~limit ~has_more ~notes
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
    match bindings with
    | None -> respond_unverified ~surface ~limit ~has_more ~notes messages
    | Some bindings ->
        (match
           classify_surface ~bindings ~has_more ~page_labels:(page_labels messages)
             surface
         with
         | None ->
             respond_unverified ~surface ~limit ~has_more ~notes messages
         | Some Unbound_connector ->
             error_json
               (Printf.sprintf "surface %s is not connected: %s" surface
                  (unbound_connector_hint bindings))
         | Some (Unknown_label labels) ->
             error_json
               (Printf.sprintf "surface %s matches no lane on this page: %s"
                  surface (unknown_label_hint labels)))
