(* How a byte figure is read in tokens, and where the ratio came from. *)

type basis =
  | This_turn of { wire_bytes : int; tokens : int }
  | Keeper_page of { samples : int }
  | Fleet_measured

type t =
  { tokens_per_byte : float
  ; basis : basis
  }

(* Median of request_body_bytes / input_tokens over the 2,004 per-request
   turn records the fleet wrote on 2026-09-13..15 (p10 3.17, p90 3.89;
   glm-5.3-flash 3.34, deepseek-v4.1-flash 3.29, minimax-m3 3.90). The last
   resort when neither this turn nor its keeper's page carries a wire body
   beside a per-request count -- every official-client lane, whose client
   assembles its own wire. *)
let fleet_bytes_per_token = 3.39

let fleet = { tokens_per_byte = 1. /. fleet_bytes_per_token; basis = Fleet_measured }

(* A per-request count over the serialized body of the same record. A
   conversation-cumulative count puts the whole conversation over one
   request's bytes, and a count of unknown scope might, so neither divides. *)
let wire_ratio_of_record (turn : Turn_record.t) =
  match turn.usage.scope with
  | Runtime_usage_scope.Conversation_cumulative
  | Runtime_usage_scope.Usage_scope_unavailable -> None
  | Runtime_usage_scope.Per_request -> (
      match turn.request_wire_observation, turn.usage.input_tokens with
      | Some { Turn_record.body_bytes; _ }, Some tokens
        when body_bytes > 0 && tokens > 0 -> Some (body_bytes, tokens)
      | Some _, Some _ | Some _, None | None, Some _ | None, None -> None)

let median sorted =
  let n = List.length sorted in
  if n = 0 then None
  else if n mod 2 = 1 then List.nth_opt sorted (n / 2)
  else
    match List.nth_opt sorted ((n / 2) - 1), List.nth_opt sorted (n / 2) with
    | Some low, Some high -> Some ((low +. high) /. 2.)
    | Some _, None | None, Some _ | None, None -> None

let of_turn ~(rows : Turn_record.t list) (turn : Turn_record.t) =
  match wire_ratio_of_record turn with
  | Some (wire_bytes, tokens) ->
      { tokens_per_byte = float tokens /. float wire_bytes
      ; basis = This_turn { wire_bytes; tokens }
      }
  | None -> (
      let ratios =
        List.filter_map
          (fun row ->
            Option.map
              (fun (wire_bytes, tokens) -> float tokens /. float wire_bytes)
              (wire_ratio_of_record row))
          rows
        |> List.sort compare
      in
      match median ratios with
      | Some tokens_per_byte ->
          { tokens_per_byte; basis = Keeper_page { samples = List.length ratios } }
      | None -> fleet)

let estimate scale bytes =
  int_of_float (Float.round (float bytes *. scale.tokens_per_byte))

let format_estimate scale bytes =
  "\xe2\x89\x88" ^ Masc_tui_context_inspector.format_tokens (estimate scale bytes)

let note scale =
  match scale.basis with
  | This_turn { wire_bytes; tokens } ->
      Printf.sprintf
        "\xe2\x89\x88 tok is bytes at this turn's %.2f bytes per \
         provider-counted token (%s tokens over %s on the wire): an \
         estimate, not a count."
        (1. /. scale.tokens_per_byte)
        (Masc_tui_context_inspector.format_tokens tokens)
        (Masc_tui_context_inspector.format_bytes wire_bytes)
  | Keeper_page { samples } ->
      Printf.sprintf
        "\xe2\x89\x88 tok is bytes at %.2f bytes per provider-counted token, \
         the median of %d turns on this page that carried a wire body beside \
         a per-request count; this turn carried neither. An estimate, not a \
         count."
        (1. /. scale.tokens_per_byte)
        samples
  | Fleet_measured ->
      Printf.sprintf
        "\xe2\x89\x88 tok is bytes at %.2f bytes per provider-counted token, \
         the fleet median measured 2026-09-13..15; no turn on this page \
         carried a wire body beside a per-request count. An estimate, not a \
         count."
        fleet_bytes_per_token
