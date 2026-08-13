(** Exact mention extraction and matching. Routing policy belongs to callers;
    this module only preserves the target bytes carried by [@target] or
    [@@target]. *)

(* The mention patterns are static. [Re.compile] runs the DFA construction once
   at module load instead of per [parse] call; on a high-broadcast workspace
   every message previously paid repeated compilations + DFA builds before [Re.exec_opt] could
   even start. *)
let broadcast_re =
  Re.(compile
        (seq [
          alt [bos; compl [rg 'A' 'Z'; rg 'a' 'z'; rg '0' '9'; char '@'; char '_'; char '-']];
          str "@@";
          group (rep1 (alt [rg 'a' 'z'; rg 'A' 'Z'; rg '0' '9'; char '_']));
          alt [eos; compl [rg 'A' 'Z'; rg 'a' 'z'; rg '0' '9'; char '_'; char '-']];
        ]))

let mention_re =
  Re.(compile
        (seq [
          alt [bos; compl [rg 'A' 'Z'; rg 'a' 'z'; rg '0' '9'; char '@'; char '_'; char '-']];
          char '@';
          group (rep1 (alt [
            rg 'a' 'z'; rg 'A' 'Z'; rg '0' '9'; char '_'; char '-';
          ]));
          alt [eos; compl [rg 'A' 'Z'; rg 'a' 'z'; rg '0' '9'; char '_'; char '-']];
        ]))

(** Extract the exact target. Fleet broadcast syntax keeps priority over a
    direct mention, matching the historical production contract. *)
let extract content =
  match Re.exec_opt broadcast_re content with
  | Some group -> Some (Re.Group.get group 1)
  | None ->
    (match Re.exec_opt mention_re content with
     | Some group -> Some (Re.Group.get group 1)
     | None -> None)

(* Target-keyed cache for [is_mentioned]'s compiled regex.

   The pattern interpolates [target] (an agent name) so it cannot
   be compiled at module load like the static parse patterns above.
   But the set of distinct targets is bounded by the agent fleet
   (~20 in production), so a Hashtbl keyed by trimmed target is
   enough — no LRU needed, the cache stabilises after warm-up.

   Without this cache, [any_mentioned ~targets content] for N
   targets re-ran [Re.compile] N times per call.  Per-keeper
   message-policy evaluation (keeper_memory_policy /
   keeper_context_runtime / keeper_prompt) re-paid that on every
   message, so with 14 keepers × per-message direct-mention checks
   the compile cost was a sustained tax.

   [Stdlib.Mutex] (not [Eio.Mutex]) because callers may run from
   non-Eio contexts and the hold time is bounded by a
   [Hashtbl.find_opt] + occasional one-shot compile per new target. *)
let is_mentioned_cache : (string, Re.re) Hashtbl.t = Hashtbl.create 32

let is_mentioned_cache_mu = Stdlib.Mutex.create ()

let compile_target_pattern target =
  Re.(compile (seq [
    (* Start of string or non-mention character *)
    group (alt [bos; compl [rg 'A' 'Z'; rg 'a' 'z'; rg '0' '9'; char '@'; char '_'; char '-']]);
    no_case (seq [char '@'; str target]);
    (* End of string or non-mention character *)
    group (alt [eos; compl [rg 'A' 'Z'; rg 'a' 'z'; rg '0' '9'; char '_'; char '-']])
  ]))

let target_re target =
  Stdlib.Mutex.protect is_mentioned_cache_mu
    (fun () ->
      match Hashtbl.find_opt is_mentioned_cache target with
      | Some re -> re
      | None ->
          let re = compile_target_pattern target in
          Hashtbl.add is_mentioned_cache target re;
          re)

let is_mentioned target content =
  let target = String.trim target in
  if target = "" then
    false
  else
    Re.execp (target_re target) content

let any_mentioned ~targets content =
  targets
  |> List.filter (fun target -> String.trim target <> "")
  |> List.exists (fun target -> is_mentioned target content)
