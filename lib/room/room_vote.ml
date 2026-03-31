(** Room Vote - Consensus / Voting System.

    Extracted from room.ml for modularity.
    Provides vote creation, casting, status, and listing. *)

open Types
open Room_utils
open Room_state

(** Voting directory *)
let votes_dir config = Filename.concat (masc_dir config) "votes"

(** Vote status type *)
type vote_status = VotePending | VoteApproved | VoteRejected | VoteTied
[@@deriving show { with_path = false }]

let vote_status_to_string = function
  | VotePending -> "pending"
  | VoteApproved -> "approved"
  | VoteRejected -> "rejected"
  | VoteTied -> "tied"

(** Create a vote proposal *)
let vote_create config ~proposer ~topic ~options ~required_votes =
  ensure_initialized config;

  if required_votes < 1 then
    Printf.sprintf "❌ required_votes must be at least 1 (got %d)" required_votes
  else if options = [] then
    "❌ options list cannot be empty"
  else begin

  mkdir_p (votes_dir config);

  let vote_id = Printf.sprintf "vote-%s-%06x" (String.sub (now_iso ()) 0 10)
    (Hashtbl.hash (Unix.gettimeofday ()) land 0xFFFFFF) in
  let vote_path = Filename.concat (votes_dir config) (vote_id ^ ".json") in

  let vote_json = `Assoc [
    ("id", `String vote_id);
    ("proposer", `String proposer);
    ("topic", `String topic);
    ("options", `List (List.map (fun s -> `String s) options));
    ("votes", `Assoc []);  (* agent -> option *)
    ("required_votes", `Int required_votes);
    ("status", `String "pending");
    ("created_at", `String (now_iso ()));
    ("resolved_at", `Null);
  ] in

  write_json config vote_path vote_json;

  (* Broadcast *)
  let _ = broadcast config ~from_agent:proposer
    ~content:(Printf.sprintf "🗳️ Vote started: %s (options: %s)" topic (String.concat ", " options)) in

  (* Log event *)
  log_event config (Printf.sprintf
    "{\"type\":\"vote_created\",\"id\":\"%s\",\"proposer\":\"%s\",\"topic\":\"%s\",\"ts\":\"%s\"}"
    vote_id proposer topic (now_iso ()));

  Printf.sprintf "🗳️ Vote created: %s\n  Topic: %s\n  Options: %s\n  Required: %d votes"
    vote_id topic (String.concat ", " options) required_votes

  end

(** Cast a vote *)
let vote_cast config ~agent_name ~vote_id ~choice =
  ensure_initialized config;

  let vote_path = Filename.concat (votes_dir config) (vote_id ^ ".json") in
  if not (Sys.file_exists vote_path) then
    Printf.sprintf "❌ Vote %s not found" vote_id
  else begin
    with_file_lock config vote_path (fun () ->
      let json = read_json config vote_path in
      let open Yojson.Safe.Util in

      let status = json |> member "status" |> to_string in
      if status <> "pending" then
        Printf.sprintf "⚠ Vote %s already resolved (%s)" vote_id status
      else begin
        let options = json |> member "options" |> to_list |> List.map to_string in
        if not (List.mem choice options) then
          Printf.sprintf "❌ Invalid choice: %s. Options: %s" choice (String.concat ", " options)
        else begin
          let votes = json |> member "votes" in
          let current_votes = match votes with
            | `Assoc kvs -> kvs
            | _ -> []
          in

          (* Reject duplicate vote *)
          if List.exists (fun (k, _) -> k = agent_name) current_votes then
            Printf.sprintf "⚠ %s has already voted on %s" agent_name vote_id
          else

          let new_votes = (agent_name, `String choice) :: current_votes in

          let required = json |> member "required_votes" |> to_int in
          let vote_count = List.length new_votes in

          (* Check if vote is resolved *)
          let resolved, new_status, winner =
            if vote_count >= required then begin
              (* Count votes per option *)
              let counts = List.fold_left (fun acc (_, v) ->
                let opt = to_string v in
                let curr = Option.value ~default:0 (List.assoc_opt opt acc) in
                (opt, curr + 1) :: (List.remove_assoc opt acc)
              ) [] new_votes in

              let max_count = List.fold_left (fun acc (_, c) -> max acc c) 0 counts in
              let winners = List.filter (fun (_, c) -> c = max_count) counts in

              match winners with
              | [(winner_choice, _)] -> (true, VoteApproved, Some winner_choice)
              | _ :: _ :: _ -> (true, VoteTied, None)
              | [] -> (true, VoteTied, None)
            end else
              (false, VotePending, None)
          in

          let updated_json = `Assoc [
            ("id", json |> member "id");
            ("proposer", json |> member "proposer");
            ("topic", json |> member "topic");
            ("options", json |> member "options");
            ("votes", `Assoc new_votes);
            ("required_votes", json |> member "required_votes");
            ("status", `String (vote_status_to_string new_status));
            ("created_at", json |> member "created_at");
            ("resolved_at", if resolved then `String (now_iso ()) else `Null);
            ("winner", Json_util.string_opt_to_json winner);
          ] in

          write_json config vote_path updated_json;

          (* Log event *)
          log_event config (Printf.sprintf
            "{\"type\":\"vote_cast\",\"id\":\"%s\",\"agent\":\"%s\",\"choice\":\"%s\",\"ts\":\"%s\"}"
            vote_id agent_name choice (now_iso ()));

          if resolved then begin
            let topic = json |> member "topic" |> to_string in
            let result_msg = match new_status, winner with
              | VoteApproved, Some w -> Printf.sprintf "Winner: %s" w
              | VoteApproved, None -> "Winner: (unknown)"
              | VoteTied, _ -> "Result: Tied!"
              | _, _ -> "Resolved"
            in
            let _ = broadcast config ~from_agent:"system"
              ~content:(Printf.sprintf "🗳️ Vote resolved: %s - %s" topic result_msg) in
            Printf.sprintf "✅ Vote cast: %s for %s\n🎉 Vote resolved! %s" agent_name choice result_msg
          end else
            Printf.sprintf "✅ Vote cast: %s for %s (%d/%d votes)"
              agent_name choice vote_count required
        end
      end
    )
  end

(** Get vote status *)
let vote_status config ~vote_id =
  ensure_initialized config;

  let vote_path = Filename.concat (votes_dir config) (vote_id ^ ".json") in
  if not (Sys.file_exists vote_path) then
    `Assoc [("error", `String (Printf.sprintf "Vote %s not found" vote_id))]
  else
    read_json config vote_path

(** List active votes *)
let list_votes config =
  ensure_initialized config;

  let votes_path = votes_dir config in
  if not (Sys.file_exists votes_path) then
    `Assoc [("votes", `List []); ("count", `Int 0)]
  else begin
    let votes = ref [] in
    Sys.readdir votes_path |> Array.iter (fun name ->
        Room_query.safe_yield ();
      if Filename.check_suffix name ".json" then begin
        let path = Filename.concat votes_path name in
        votes := read_json config path :: !votes
      end
    );
    `Assoc [
      ("votes", `List (List.rev !votes));
      ("count", `Int (List.length !votes));
    ]
  end
