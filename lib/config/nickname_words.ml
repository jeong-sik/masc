(** Shared adjective/animal word lists for MASC agent nicknames.

    Single source of truth consumed by both the workspace-side generator
    ([Nickname.generate]) and the auth-side classifier ([Auth_nickname]). Auth
    sits below masc_workspace in the module graph and cannot depend on
    [Nickname]; it previously kept an inline copy of these lists. Both paths now
    read from here so the adjective/animal vocabulary cannot drift between the
    generator and the classifier. *)

let adjectives =
  [| "swift"
   ; "brave"
   ; "calm"
   ; "eager"
   ; "fierce"
   ; "gentle"
   ; "happy"
   ; "jolly"
   ; "keen"
   ; "lucky"
   ; "merry"
   ; "noble"
   ; "proud"
   ; "quick"
   ; "witty"
   ; "bold"
   ; "cool"
   ; "deft"
   ; "fair"
   ; "grand"
   ; "hale"
   ; "jade"
   ; "kind"
   ; "lean"
   ; "neat"
   ; "pale"
   ; "rare"
   ; "sage"
   ; "tame"
   ; "warm"
  |]

let animals =
  [| "fox"
   ; "bear"
   ; "wolf"
   ; "hawk"
   ; "lion"
   ; "tiger"
   ; "eagle"
   ; "otter"
   ; "panda"
   ; "koala"
   ; "raven"
   ; "falcon"
   ; "badger"
   ; "beaver"
   ; "whale"
   ; "shark"
   ; "crane"
   ; "heron"
   ; "moose"
   ; "viper"
   ; "cobra"
   ; "gecko"
   ; "lemur"
   ; "llama"
   ; "manta"
   ; "orca"
   ; "rhino"
   ; "sloth"
   ; "tapir"
   ; "zebra"
  |]
