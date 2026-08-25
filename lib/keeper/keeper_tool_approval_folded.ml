module Descriptor = Keeper_tool_descriptor
module Policy = Keeper_tool_approval_policy
module Catalog = Keeper_tool_composition_catalog
module Plan = Keeper_tool_plan

(* Where folded verdicts live.

   The composition surface materializes tools that the descriptor registry
   does not know: keeper_compose_<skill> and keeper_plan_execute are built
   from Agent-Core descriptors, so [Policy.verdict_for] falls into its
   "no descriptor" arm and asks about a read-only DAG whose nodes would
   each run unasked if called directly. That is a wrong question: the fold
   is knowable at bundle build time, when the entry's plan is already
   validated. This table holds that fold.

   Constraints honored here:
   - reading is pure: the hook ([hook_event -> hook_decision]) has no [sw]
     and no [result], so the lookup must not fail or block;
   - lifetime equals the bundle that materialized the composition tools
     (the skill catalog's lifetime, in-process) — no durable state;
   - the fold cannot be more permissive than the nodes: a node whose
     descriptor cannot be resolved is not folded to Run. *)
let folded : (string, Policy.verdict) Hashtbl.t = Hashtbl.create 16

let register ~tool_name verdict = Hashtbl.replace folded tool_name verdict

let lookup tool_name = Hashtbl.find_opt folded tool_name

(* The input a frozen composition node would run with: templates that carry
   no unresolved reference. A node that cannot resolve is reported as such
   rather than guessed at — the caller folds an Ask for it.

   [Param] leaves are caller-bound at invocation, so they are treated as a
   still-unknown literal rather than a resolution failure: the fold asks
   about the composition when a param-dependent node would need its bound
   value classified. *)
let frozen_input_of_node (node : Plan.node) : Yojson.Safe.t option =
  match
    Plan.Json_template.resolve
      ~lookup:(fun _ -> None)
      node.Plan.input
  with
  | Ok json -> Some json
  | Error (Plan.Json_template.Param_not_substituted _) -> Some `Null
  | Error _ -> None

(* Fold one validated composition entry into a single verdict:
   every node Run makes the composition Run; any Ask makes the composition
   Ask, with the asking node's tool name carried in [because]. *)
let fold_entry (entry : Catalog.entry) : Policy.verdict =
  let nodes = Plan.nodes entry.plan in
  let asking =
    List.filter_map
      (fun (node : Plan.node) ->
         match frozen_input_of_node node with
         | None ->
           Some
             (Policy.Ask
                { because =
                    Printf.sprintf
                      "composition node %s has an input that cannot be resolved"
                      node.tool_name
                })
         | Some input -> (
             match Policy.verdict_for ~tool_name:node.tool_name ~input with
             | Ask _ as ask -> Some ask
             | Run _ -> None))
      nodes
  in
  match asking with
  | ask :: _ -> ask
  | [] -> Run { because = "every node in the composition only reads" }

let register_entry ~(entry : Catalog.entry) =
  register ~tool_name:(Catalog.tool_name entry) (fold_entry entry)

(* The verdict for a call to a folded composition tool. The input argument is
   carried for signature symmetry with [Policy.verdict_for] — the fold was
   made against the validated entry plan, and caller arguments only bind
   params, so the fold already covers what the call would do. *)
let verdict_for_folded ~tool_name ~input =
  match lookup tool_name with
  | Some verdict -> Some verdict
  | None ->
      (* A folded-shaped tool that was never registered is asked about, never
         run: the table is the authority the bundle stamped. *)
      ignore input;
      None
