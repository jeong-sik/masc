module L = Masc.Keeper_skill_activation_ledger
let summarize (ledger : L.t) = L.summary_to_yojson (L.summarize ledger)
