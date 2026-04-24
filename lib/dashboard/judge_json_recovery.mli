(* Recover a JSON object from LLM output that prefixes or suffixes prose.
   Returns the first balanced {...} substring, or None if no well-formed
   object opens-and-closes in the input. String-literal aware. *)

val extract_balanced_object : string -> string option
