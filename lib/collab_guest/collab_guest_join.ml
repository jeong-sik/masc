type target = {
  room_id : string;
  key : Collab_seal.key;
  capability : Collab_link.capability;
  write_token : string option;
  ws_secure : bool;
  ws_host : string;
  ws_port : int;
}

type resolve_error =
  | Bad_link of string
  | Bad_relay of string
  | Relay_missing

let resolve_error_to_string = function
  | Bad_link detail -> "bad share link: " ^ detail
  | Bad_relay detail -> "bad relay: " ^ detail
  | Relay_missing ->
    "a terminal link names no relay; pass --relay ws(s)://host:port (a browser link carries its own)"
;;

let link_error_to_string = function
  | Collab_link.Missing_separator -> "missing room.secret separator"
  | Collab_link.Invalid_room_id -> "room id is not 16 base64url bytes"
  | Collab_link.Invalid_secret -> "secret is not base64url"
  | Collab_link.Invalid_secret_length n ->
    Printf.sprintf "secret is %d bytes, not 32 (view) or 48 (control)" n
  | Collab_link.Missing_fragment -> "missing #fragment"
;;

let resolve ~link ~relay =
  let trimmed = String.trim link in
  let parsed =
    match String.rindex_opt trimmed '#' with
    | None -> (
      match Collab_link.parse_link trimmed with
      | Error err -> Error (Bad_link (link_error_to_string err))
      | Ok parsed -> Ok (parsed, None))
    | Some hash -> (
      let base = String.sub trimmed 0 hash in
      match Collab_link.parse_web_link trimmed with
      | Error err -> Error (Bad_link (link_error_to_string err))
      | Ok parsed -> Ok (parsed, Some base))
  in
  match parsed with
  | Error _ as error -> error
  | Ok (parsed, base) -> (
    let relay_src =
      match relay, base with
      | Some override, _ -> Some override
      | None, Some base -> Some base
      | None, None -> None
    in
    match relay_src with
    | None -> Error Relay_missing
    | Some raw -> (
      match Collab_origin.parse ~schemes:[ "http"; "https"; "ws"; "wss" ] raw with
      | Error err -> Error (Bad_relay (Collab_origin.parse_error_to_string err))
      | Ok origin -> (
        match Collab_seal.key_of_secret parsed.Collab_link.key with
        | Error _ -> Error (Bad_link "room key rejected")
        | Ok key ->
          let ws_secure =
            match origin.Collab_origin.scheme with
            | "https" | "wss" -> true
            | _ -> false
          in
          let ws_port =
            match origin.Collab_origin.port with
            | Some p -> p
            | None -> if ws_secure then 443 else 80
          in
          Ok
            { room_id = parsed.Collab_link.id
            ; key
            ; capability = parsed.Collab_link.capability
            ; write_token = parsed.Collab_link.write_token
            ; ws_secure
            ; ws_host = origin.Collab_origin.host
            ; ws_port
            })))
;;

let resource target =
  Printf.sprintf "/r/%s?role=guest"
    (Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet target.room_id)
;;

type event =
  | Snapshot_row of Yojson.Safe.t
  | Live_entry of Collab_frame.entry
  | State of Collab_frame.live_state
  | Transcript of Collab_frame.transcript
  | Bye of string
  | Error_frame of string

module Op_seq = Set.Make (struct
  type t = string * int

  let compare = compare
end)

type phase =
  | Awaiting_welcome of { buffered : Collab_frame.entry list }
  | Snapshot of {
      op : string;
      seen : Op_seq.t;
      buffered : Collab_frame.entry list;
    }
  | Live of { seen : Op_seq.t }

type t = { mutable phase : phase }

let create () = { phase = Awaiting_welcome { buffered = [] } }

let row_seq row =
  match row with
  | `Assoc fields -> (
    match List.assoc_opt "seq" fields with
    | Some (`Int n) -> Some n
    | _ -> None)
  | _ -> None
;;

let feed t frame =
  match t.phase, frame with
  | _, Collab_frame.Live_state state -> [ State state ]
  | _, Collab_frame.Transcript transcript -> [ Transcript transcript ]
  | _, Collab_frame.Bye reason -> [ Bye reason ]
  | _, Collab_frame.Error_frame message -> [ Error_frame message ]
  | _, (Collab_frame.Hello _ | Collab_frame.Prompt _ | Collab_frame.Abort | Collab_frame.Fetch_transcript _) ->
    (* Guest-bound frames never come from the host. *)
    []
  | Awaiting_welcome { buffered }, Collab_frame.Welcome welcome ->
    t.phase <- Snapshot { op = welcome.Collab_frame.header.operation; seen = Op_seq.empty; buffered };
    [ State welcome.Collab_frame.state ]
  | Snapshot _, Collab_frame.Welcome welcome ->
    (* A second welcome (a re-hello's answer) updates state without
       resetting the join: the snapshot in flight stays authoritative. *)
    [ State welcome.Collab_frame.state ]
  | Live _, Collab_frame.Welcome welcome -> [ State welcome.Collab_frame.state ]
  | Awaiting_welcome { buffered }, Collab_frame.Entry entry ->
    t.phase <- Awaiting_welcome { buffered = buffered @ [ entry ] };
    []
  | Snapshot s, Collab_frame.Entry entry ->
    t.phase <- Snapshot { s with buffered = s.buffered @ [ entry ] };
    []
  | Live live, Collab_frame.Entry entry ->
    if Op_seq.mem (entry.Collab_frame.op, entry.Collab_frame.op_seq) live.seen
    then []
    else [ Live_entry entry ]
  | (Awaiting_welcome _ | Live _), Collab_frame.Snapshot_chunk _ ->
    (* Chunks outside a snapshot (a stray hello's shadow) carry rows for
       no join in progress; dropping them beats mis-ordering the view. *)
    []
  | Snapshot s, Collab_frame.Snapshot_chunk chunk ->
    let seen =
      List.fold_left
        (fun acc row ->
          match row_seq row with
          | None -> acc
          | Some seq -> Op_seq.add (s.op, seq) acc)
        s.seen chunk.Collab_frame.entries
    in
    let rows = List.map (fun row -> Snapshot_row row) chunk.Collab_frame.entries in
    if chunk.Collab_frame.final
    then (
      let fresh =
        List.filter
          (fun (entry : Collab_frame.entry) ->
            not (Op_seq.mem (entry.Collab_frame.op, entry.Collab_frame.op_seq) seen))
          s.buffered
      in
      t.phase <- Live { seen };
      rows @ List.map (fun entry -> Live_entry entry) fresh)
    else (
      t.phase <- Snapshot { s with seen };
      rows)
;;
