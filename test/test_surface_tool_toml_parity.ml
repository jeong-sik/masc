(** Byte-identity pins for the surface tool toml parity declarations moving to
    [config/tools/*.toml] (RFC prompts-and-tool-definitions-outside-ocaml
    §2.2).

    The expected values were read off [Tool_shard_types.surface_tools] before any file moved, so this
    suite passing *before* the TOML replaces a literal is what proves the file
    says the same thing. Written against the published list rather than a loader
    module, so it holds across the whole migration: what a Keeper receives must
    not move whether a declaration lives in OCaml or TOML.

    The wording moved on purpose. These three tools were declared twice -- once
    here and once in keeper_tool_descriptor.ml, whose copy the model actually
    received -- and the two disagreed on fifteen parameter sentences. The
    descriptor's were the more accurate: it said Discord members go to 1000
    where this one still said 100. That copy is gone and its sentences are here.

    keeper_surface_read.before stays. Only this side declared it, and
    keeper_tool_in_process_runtime.ml:833 reads it for local-lane pagination,
    so the model was being handed a schema that hid a parameter it could use.

    Compared as parsed JSON with keys sorted, per RFC §4 -- object key order is
    not part of a JSON object's meaning, and TOML cannot place a sub-table
    before its parent's scalar keys. *)

open Alcotest

let rec sorted (json : Yojson.Safe.t) : Yojson.Safe.t =
  match json with
  | `Assoc fields ->
    `Assoc
      (fields
       |> List.map (fun (key, value) -> key, sorted value)
       |> List.sort (fun (a, _) (b, _) -> String.compare a b))
  | `List items -> `List (List.map sorted items)
  | other -> other
;;

(* name, description, input_schema (keys sorted) *)
let expected =
    [ {|keeper_surface_read|}, {|Read recent messages from one conversation endpoint (dashboard, discord, slack, or another connector label) with speaker identity and a derived participant roster. With mode='channel', 'messages', 'members', or 'member', the Discord lane can also query its live channel and server read surface within the keeper's bound channels.|}, {|{"properties":{"before":{"description":"Page backward: return messages strictly older than this ts (a message timestamp from a previous call). Walk history by passing the oldest_ts of the previous response; stop when has_more is false.","type":"number"},"channel_id":{"description":"Bound Discord channel snowflake. Optional when this keeper has one bound channel; required when it has multiple.","type":"string"},"discord_after":{"description":"Discord message/member snowflake for forward paging. Do not send it together with discord_before.","type":"string"},"discord_before":{"description":"Discord message snowflake for backward paging in mode='messages'.","type":"string"},"limit":{"description":"Maximum messages or Discord members to return (default 20; messages: 1-100; members: 1-1000). The local participant roster covers the whole loaded lane.","type":"integer"},"mode":{"description":"Optional exact read mode. When absent, the request is exactly 'local' for the persisted lane; padded or unknown values are invalid. The other modes query Discord live and require surface='discord'.","enum":["local","channel","messages","members","member"],"type":"string"},"query":{"description":"Optional member username/nickname prefix for mode='members'.","type":"string"},"surface":{"description":"Lane label exactly as shown in Connected Surfaces or chat history source: 'dashboard', 'discord', 'slack', or another connector's channel label. Rows written before source labelling carry no label and are not returned.","type":"string"},"user_id":{"description":"Discord user snowflake, required for mode='member'.","type":"string"}},"required":["surface"],"type":"object"}|}
    ; {|keeper_surface_post|}, {|Post a message to one conversation endpoint: 'dashboard' (appears in the operator's chat transcript), 'discord', or 'slack'. Standard Markdown is rendered natively by Discord and by Slack's Block Kit markdown block. To create a real highlighted user mention, pass stable participant-roster ids in mention_user_ids; never guess ids from display names. A Slack post may reply inside an existing thread (thread_ts) or carry Block Kit blocks; see those parameters. Posting to an unbound surface is an error. These endpoints are read by a person, so an unchanged status reposted every cycle crowds their view and says nothing the previous one did not; when there is nothing new, the turn ends without a post. This is a terminal-contract tool: when it succeeds, the turn ends. The runtime rejects any batch that places it alongside another tool call — call it alone in its own turn, never batched with reads, writes, or shell execution.|}, {|{"properties":{"blocks":{"description":"Slack Block Kit blocks for chat.postMessage (at most 50, each a block object with a \"type\" member). Slack surface only. content stays the notification fallback text; when omitted, content renders as one markdown block. Rendering mentions inside custom blocks is the author's responsibility; mention_user_ids are still roster-validated.","items":{"type":"object"},"maxItems":50,"type":"array"},"channel_id":{"description":"Omit this to reply in the channel the message you are answering came from — it defaults to that channel, which is the usual case for replying to a mention. Set it only to post to a different channel than the one in hand. It names a channel, never the surface: a bound Discord or Slack channel id, or that channel's name (with or without a leading '#') — not the word 'discord' or 'slack'. A name resolves to the bound channel's id automatically; the channel must be bound and have received at least one message so its name is known. Unresolvable references are rejected.","type":"string"},"content":{"description":"Standard Markdown message to deliver. Discord renders it natively; Slack renders it through the official Block Kit markdown block. When blocks is provided, content is only the Slack notification fallback text.","type":"string"},"mention_user_ids":{"description":"Stable ids from keeper_surface_read participants to visibly mention. Slack requires U.../W... ids; Discord requires decimal user snowflakes. Never guess an id from a display name; plain @name text is not an API mention.","items":{"type":"string"},"maxItems":100,"type":"array"},"surface":{"description":"Lane to post to: 'dashboard', 'discord', or 'slack'. Posting to a surface this keeper is not bound to is an error, not a no-op.","type":"string"},"thread_ts":{"description":"Slack timestamp of an existing thread's root message (from keeper_surface_read). Posts this message as a reply inside that thread. Slack surface only; when both this and a continuation thread exist, this value wins.","type":"string"}},"required":["surface","content"],"type":"object"}|}
    ; {|keeper_person_note_set|}, {|Remember, or clear, a note about a person met on a connected surface.

The note is keyed by their roster speaker_id. Deliberate memory: the note survives after their chat rows age out of the log window and shows up on the keeper_surface_read roster.|}, {|{"properties":{"note":{"description":"What to remember about this person. Blank clears the note (tombstone).","type":"string"},"speaker_id":{"description":"Stable speaker id from the roster (Discord snowflake). Notes attach to ids, never to display names.","type":"string"}},"required":["speaker_id","note"],"type":"object"}|}
    ]
;;

let published = Tool_shard_types.surface_tools

let find name =
  match
    List.find_opt (fun (s : Masc_domain.tool_schema) -> String.equal s.name name) published
  with
  | Some schema -> schema
  | None -> failwith (name ^ " is absent from Tool_shard_types.surface_tools")
;;

let test_descriptions_are_byte_identical () =
  List.iter
    (fun (name, description, _) ->
       check string (name ^ " description") description (find name).description)
    expected
;;

let test_input_schemas_match_with_keys_sorted () =
  List.iter
    (fun (name, _, schema) ->
       check
         string
         (name ^ " input_schema")
         schema
         (Yojson.Safe.to_string (sorted (find name).input_schema)))
    expected
;;

(* The order is what a model reads the tool list in, so a reordering is a
   change to the surface even when every schema still matches. *)
let test_the_published_order_is_unchanged () =
  check
    (list string)
    "Tool_shard_types.surface_tools in order"
    (List.map (fun (name, _, _) -> name) expected)
    (List.map (fun (s : Masc_domain.tool_schema) -> s.name) published)
;;

let () =
  run
    "surface_tool_toml_parity"
    [ ( "byte_identity"
      , [ test_case "descriptions" `Quick test_descriptions_are_byte_identical
        ; test_case
            "input schemas, keys sorted"
            `Quick
            test_input_schemas_match_with_keys_sorted
        ; test_case "published order" `Quick test_the_published_order_is_unchanged
        ] )
    ]
;;
