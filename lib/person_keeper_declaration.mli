(** The declaration a person's Keeper is created with (RFC
    a-persons-keeper-runs-on-the-engine, S2 / stack A3-2).

    A person's Keeper is a record of the authorization log plus one
    [keepers/<engine_name>.toml] file: the log names the owner, the engine
    name and the Runtime, and the declaration is what the engine reads when it
    starts the Keeper. The multi-account boot refuses a definition the log does
    not name ({!Server_accounts.no_keeper_definition}), so the two are written
    in that order: the log first, the declaration second.

    {b What this module decides, and what it does not.} It renders the bytes of
    that declaration and nothing else. Writing them, deciding who writes them
    and repairing a Keeper whose declaration is missing belong to the caller.
    Keeping the shape here means the values are reviewed once, and a test can
    hand the rendered bytes to the real loader
    ({!Keeper_types_profile_toml.inspect_keeper_toml_content}) instead of
    trusting a hand-copied fixture.

    {b The values.}
    - [activation_mode = "on_demand"]: the person's Keeper runs when the person
      writes to it. It does not start by itself: the autonomous mode is a later
      step of the RFC (§3.5, S3), and a Keeper that starts on its own before
      that step exists would start turns nobody asked for.
    - [tools.masc_enabled = false]: a person's Keeper runs without tools
      (RFC §2, "사람의 Keeper 는 도구 없이 돈다"). The value is written out
      rather than left to a default, because it is the guarantee A3-1 made
      enforceable and a reader of the file should see it.
    - [sandbox_profile], [sandbox_image], [network_mode]: the shipped default
      declaration of a fresh install ([config/keepers-default/imp.toml]) uses
      the same three. The RFC does not read what a tool-less Keeper needs here
      (§4, "sandbox"), so this follows the shipped default rather than
      inventing a value. Changing it changes where a person's Keeper runs, and
      that is a decision, not a detail. *)

(** The instructions of a person's Keeper.

    Fixed text: the declaration is written before anything of the person's
    first conversation exists, so there is nothing to interpolate. A turn reads
    it as the Keeper's own instructions, not as the system prompt of the
    client. *)
val instructions : string

(** The complete declaration, ready to be validated and written at
    [keepers/<engine_name>.toml].

    The bytes name no [keeper.name]: the loader derives the name from the file
    name and refuses a key that disagrees with it. *)
val content : unit -> string
