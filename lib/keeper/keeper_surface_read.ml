module Store = Keeper_chat_store

type participant = {
  id : string;
  name : string option;
  authority : Store.speaker_authority;
  first_seen : float;
  last_seen : float;
  message_count : int;
}

let default_limit = 20
let max_limit = 100
let normalize_limit limit = min max_limit (max 1 limit)

let opt_string_field key = function
  | Some value when String.trim value <> "" -> [ (key, `String value) ]
  | Some _ | None -> []

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
  `Assoc
    ([ ("role", `String (Store.Role.to_label m.role));
       ("content", `String m.content) ]
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
    @ [ ("first_seen", `Float p.first_seen)
      ; ("last_seen", `Float p.last_seen)
      ; ("message_count", `Int p.message_count) ])

module String_map = Map.Make (String)

(* Roster fold: one bucket per speaker_id over user lines. The most
   recent non-empty name wins (people rename; the log remembers, the
   roster reports the latest). *)
let roster (lane : Store.chat_message list) : participant list =
  let by_id =
    List.fold_left
      (fun acc (m : Store.chat_message) ->
         match m.speaker with
         | Some { speaker_id = Some id; speaker_name; speaker_authority } ->
           let updated =
             match String_map.find_opt id acc with
             | None ->
               { id
               ; name = speaker_name
               ; authority = speaker_authority
               ; first_seen = m.ts
               ; last_seen = m.ts
               ; message_count = 1
               }
             | Some p ->
               { p with
                 name =
                   (match speaker_name with
                    | Some n when String.trim n <> "" -> Some n
                    | Some _ | None -> p.name)
               ; last_seen = m.ts
               ; message_count = p.message_count + 1
               }
           in
           String_map.add id updated acc
         | Some { speaker_id = None; _ } | None -> acc)
      String_map.empty
      lane
  in
  String_map.fold (fun _id p acc -> p :: acc) by_id []
  |> List.sort (fun a b -> Float.compare b.last_seen a.last_seen)

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
   absent -> unknown. A page is one window of the history, so an absence
   proves the label wrong only when that window is the whole history: no
   requested cursor (nothing newer was skipped) and no next cursor (nothing
   older remains). Otherwise a gate lane whose rows sit outside the window
   reads as an empty page, and the cursor keeps paging. Same trimmed-exact
   comparison as the filter. *)
let classify_surface ~bindings ~whole_history ~(page_labels : string list)
    surface =
  let surface = String.trim surface in
  match surface with
  | "dashboard" | "agent" | "broadcast" | "webhook" -> None
  | "slack" ->
      if bindings.slack = [] then Some Unbound_connector else None
  | "discord" ->
      if bindings.discord = [] then Some Unbound_connector else None
  | _ ->
      if List.mem surface page_labels || not whole_history then None
      else Some (Unknown_label page_labels)

let respond_unverified ~surface (page : Store.history_page) : string =
  (* The store applies the limit before the lane filter. Every matching row
     must be returned before publishing that page's next cursor. *)
  let lane =
    List.filter
      (fun (m : Store.chat_message) ->
        match m.surface with
        | Some typed_surface ->
          String.equal
            (Surface_ref.lane_label typed_surface |> String.trim)
            surface
        | None -> false)
      page.history_messages
  in
  Yojson.Safe.to_string
    (`Assoc
      [ "surface", `String surface
      ; "messages", `List (List.map message_json lane)
      ; "participants", `List (List.map participant_json (roster lane))
      ; "lane_row_count", `Int (List.length lane)
      ; "returned", `Int (List.length lane)
      ; "has_more", `Bool (Option.is_some page.next_cursor)
      ; "next_cursor", (match page.next_cursor with
          | Some cursor -> `String (Keeper_chat_history_page.cursor_to_string cursor)
          | None -> `Null)
      ])

(* The tool entry: a blank surface is refused, then — only when the
   runtime supplied binding knowledge — a label that can be proven wrong is
   refused instead of answered with a silent zero-row page. Without
   [bindings] the projection stays unverified. *)
let respond ?bindings ~surface ~cursor
    (page : Store.history_page) : (string, string) result =
  let surface = String.trim surface in
  if surface = "" then
    Error
      "surface is required. Use a lane label shown in Connected \
       Surfaces or chat history; this tool reads that connected lane, \
       not a connector-wide channel registry."
  else
    match bindings with
    | None -> Ok (respond_unverified ~surface page)
    | Some bindings ->
        (match
           classify_surface ~bindings
             ~whole_history:(Option.is_none cursor && Option.is_none page.next_cursor)
             ~page_labels:(page_labels page.history_messages) surface
         with
         | None ->
             Ok (respond_unverified ~surface page)
         | Some Unbound_connector ->
             Error
               (Printf.sprintf "surface %s is not connected: %s" surface
                  (unbound_connector_hint bindings))
         | Some (Unknown_label labels) ->
             Error
               (Printf.sprintf "surface %s matches no lane on this page: %s"
                  surface (unknown_label_hint labels)))
