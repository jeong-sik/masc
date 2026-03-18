(** Chain Iteration - GoalDriven Iteration Variable Substitution

    Provides iteration-aware variable substitution for GoalDriven loops.
    Supports dynamic prompt interpolation based on iteration progress.
*)

(** {1 Types} *)

(** Iteration context for GoalDriven loops - enables dynamic prompt variables *)
type iteration_ctx = {
  iteration: int;           (** Current iteration number (1-based) *)
  max_iterations: int;      (** Maximum iterations allowed *)
  progress: float;          (** Current progress toward goal (0.0 to 1.0+) *)
  last_value: float;        (** Last measured metric value *)
  goal_value: float;        (** Target goal value *)
  strategy: string option;  (** Current strategy hint if any *)
}

(** {1 Substitution} *)

(** Substitute iteration-aware variables in prompt
    Supports:
    - {{iteration}} - current iteration number (1-based)
    - {{max_iterations}} - maximum iterations allowed
    - {{progress}} - current progress toward goal (0.0 to 1.0+)
    - {{last_value}} - last measured metric value
    - {{goal_value}} - target goal value
    - {{strategy}} - current strategy hint (or "default")
    - {{linear:start,end}} - linear interpolation based on progress
    - {{step:v1,v2,v3,...}} - step function based on iteration
*)
let substitute_vars (prompt : string) (iter_ctx : iteration_ctx option) : string =
  match iter_ctx with
  | None -> prompt
  | Some ctx ->
      let replace_var s var_name replacement =
        let pattern = "{{" ^ var_name ^ "}}" in
        let buf = Buffer.create (String.length s) in
        let rec replace start =
          match String.index_from_opt s start '{' with
          | None -> Buffer.add_substring buf s start (String.length s - start)
          | Some i ->
              if i + String.length pattern <= String.length s &&
                 String.sub s i (String.length pattern) = pattern then begin
                Buffer.add_substring buf s start (i - start);
                Buffer.add_string buf replacement;
                replace (i + String.length pattern)
              end else begin
                (* Pattern didn't match - add content from start to i+1 and continue *)
                Buffer.add_substring buf s start (i - start + 1);
                replace (i + 1)
              end
        in
        replace 0;
        Buffer.contents buf
      in
      (* Basic variable substitution *)
      let result = prompt in
      let result = replace_var result "iteration" (string_of_int ctx.iteration) in
      let result = replace_var result "max_iterations" (string_of_int ctx.max_iterations) in
      let result = replace_var result "progress" (Printf.sprintf "%.2f" ctx.progress) in
      let result = replace_var result "last_value" (Printf.sprintf "%.2f" ctx.last_value) in
      let result = replace_var result "goal_value" (Printf.sprintf "%.2f" ctx.goal_value) in
      let result = replace_var result "strategy" (Option.value ctx.strategy ~default:"default") in

      (* Linear interpolation: {{linear:start,end}} *)
      let linear_regex = Str.regexp "{{linear:\\([0-9.]+\\),\\([0-9.]+\\)}}" in
      let result = Str.global_substitute linear_regex (fun s ->
        try
          let start_val = float_of_string (Str.matched_group 1 s) in
          let end_val = float_of_string (Str.matched_group 2 s) in
          let t = float_of_int (ctx.iteration - 1) /. float_of_int (max 1 (ctx.max_iterations - 1)) in
          let interpolated = start_val +. (end_val -. start_val) *. t in
          Printf.sprintf "%.2f" interpolated
        with Failure _ | Not_found -> Str.matched_string s
      ) result in

      (* Step function: {{step:v1,v2,v3,...}} *)
      let step_regex = Str.regexp "{{step:\\([^}]+\\)}}" in
      let result = Str.global_substitute step_regex (fun s ->
        try
          let values_str = Str.matched_group 1 s in
          let values = String.split_on_char ',' values_str in
          let idx = min (ctx.iteration - 1) (max 0 (List.length values - 1)) in
          match Chain_utils.list_nth_opt values (max 0 idx) with
          | Some v -> String.trim v
          | None -> Str.matched_string s
        with Not_found | Failure _ -> Str.matched_string s
      ) result in

      result
