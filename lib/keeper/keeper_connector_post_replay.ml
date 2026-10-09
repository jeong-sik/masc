let connector_post_gate_input ~connector ~channel_id ~content ~mention_user_ids
    ?thread_ts ?blocks () =
  let thread_ts_fields =
    match thread_ts with
    | None -> []
    | Some thread_ts -> [ "thread_ts", `String thread_ts ]
  in
  let block_fields =
    match blocks with
    | None -> []
    | Some blocks -> [ "blocks", `List blocks ]
  in
  `Assoc
    ([ "connector", `String connector
     ; "channel_id", `String channel_id
     ; "content", `String content
     ; "mention_user_ids", Json_util.json_string_list mention_user_ids
     ]
     @ thread_ts_fields
     @ block_fields)
;;

type connector_post_replay =
  | Replay_discord_post of
      { input : Yojson.Safe.t
      ; channel_id : string
      ; content : string
      ; mention_user_ids : string list
      }
  | Replay_slack_post of
      { input : Yojson.Safe.t
      ; channel_id : string
      ; thread_ts : string option
      ; content : string
      ; blocks : Yojson.Safe.t list
      ; mention_user_ids : string list
      }

let connector_post_replay_of_gate_input input =
  let required_string key fields =
    match
      List.filter_map
        (fun (name, value) ->
           if String.equal name key then Some value else None)
        fields
    with
    | [ `String value ] when not (String.equal (String.trim value) "") ->
      Ok value
    | [ `String _ ] ->
      Error (Printf.sprintf "approved connector_post %s is blank" key)
    | [ _ ] ->
      Error
        (Printf.sprintf "approved connector_post %s must be a string" key)
    | [] ->
      Error (Printf.sprintf "approved connector_post is missing %s" key)
    | _ ->
      Error (Printf.sprintf "approved connector_post repeats %s" key)
  in
  (* An absent optional thread coordinate stays absent; a present coordinate
     must be a usable value. *)
  let optional_string key fields =
    match
      List.filter_map
        (fun (name, value) ->
           if String.equal name key then Some value else None)
        fields
    with
    | [] -> Ok None
    | [ `String value ] when not (String.equal (String.trim value) "") ->
      Ok (Some value)
    | [ `String _ ] ->
      Error (Printf.sprintf "approved connector_post %s is blank" key)
    | [ _ ] ->
      Error
        (Printf.sprintf "approved connector_post %s must be a string" key)
    | _ ->
      Error (Printf.sprintf "approved connector_post repeats %s" key)
  in
  let required_string_list key fields =
    match
      List.filter_map
        (fun (name, value) -> if String.equal name key then Some value else None)
        fields
    with
    | [ `List values ] ->
      let rec decode acc = function
        | [] -> Ok (List.rev acc)
        | `String value :: rest when String.trim value <> "" ->
          decode (String.trim value :: acc) rest
        | `String _ :: _ ->
          Error (Printf.sprintf "approved connector_post %s contains a blank id" key)
        | _ :: _ ->
          Error
            (Printf.sprintf
               "approved connector_post %s must contain only strings"
               key)
      in
      decode [] values
    | [ _ ] ->
      Error (Printf.sprintf "approved connector_post %s must be an array" key)
    | [] -> Error (Printf.sprintf "approved connector_post is missing %s" key)
    | _ -> Error (Printf.sprintf "approved connector_post repeats %s" key)
  in
  let reject_unknown ~allowed fields =
    match
      fields
      |> List.filter_map (fun (name, _) ->
        if List.mem name allowed then None else Some name)
      |> List.sort_uniq String.compare
    with
    | [] -> Ok ()
    | names ->
      Error
        (Printf.sprintf
           "approved connector_post has unknown field(s): %s"
           (String.concat ", " names))
  in
  match input with
  | `Assoc fields ->
    let open Result.Syntax in
    let* connector = required_string "connector" fields in
    let* channel_id = required_string "channel_id" fields in
    let* content = required_string "content" fields in
    (* [connector_post_gate_input] always writes the list (empty when there
       are no mentions), so an absent field is a malformed request. *)
    let* mention_user_ids = required_string_list "mention_user_ids" fields in
    let* validated_mention_user_ids =
      Keeper_surface_post.user_mentions_of_args
        ~surface:connector
        (`Assoc [ "mention_user_ids", Json_util.json_string_list mention_user_ids ])
    in
    let* mention_user_ids =
      if validated_mention_user_ids = mention_user_ids then Ok mention_user_ids
      else
        Error
          "approved connector_post mention_user_ids must be sorted and unique"
    in
    if String.equal connector Keeper_surface_post.discord_label
    then (
      let* () =
        reject_unknown
          ~allowed:[ "connector"; "channel_id"; "content"; "mention_user_ids" ]
          fields
      in
      Ok
        (Replay_discord_post
           { input; channel_id; content; mention_user_ids }))
    else if String.equal connector Keeper_surface_post.slack_label
    then (
      let* () =
        reject_unknown
          ~allowed:
            [ "connector"
            ; "channel_id"
            ; "thread_ts"
            ; "content"
            ; "blocks"
            ; "mention_user_ids"
            ]
          fields
      in
      let* thread_ts = optional_string "thread_ts" fields in
      match
        List.filter_map
          (fun (name, value) ->
             if String.equal name "blocks" then Some value else None)
          fields
      with
      | [ `List blocks ] ->
        Ok
          (Replay_slack_post
             { input; channel_id; thread_ts; content; blocks; mention_user_ids })
      | [ _ ] ->
        Error "approved connector_post blocks must be an array"
      | [] ->
        Error "approved Slack connector_post is missing blocks"
      | _ ->
        Error "approved connector_post repeats blocks")
    else
      Error
        (Printf.sprintf
           "approved connector_post connector %S is unsupported"
           connector)
  | _ -> Error "approved connector_post input must be an object"
;;

let connector_post_replay_target = function
  | Replay_discord_post { channel_id; _ } ->
    Keeper_surface_post.To_discord { channel_id }
  | Replay_slack_post { channel_id; thread_ts; blocks; _ } ->
    Keeper_surface_post.To_slack
      { channel_id; thread_ts; blocks = Some blocks }
;;

(* What a connector_post approval is about, in one line: where the post
   goes and the first line of what it says, both from the typed request. *)
let connector_post_call_summary replay =
  let line ~connector ~channel_id ~content =
    Option.map
      (fun first_line ->
         Printf.sprintf "%s %s: %s" connector channel_id first_line)
      (String_util.first_nonblank_line content)
  in
  match replay with
  | Replay_discord_post { channel_id; content; _ } ->
    line ~connector:Keeper_surface_post.discord_label ~channel_id ~content
  | Replay_slack_post { channel_id; content; _ } ->
    line ~connector:Keeper_surface_post.slack_label ~channel_id ~content
;;
