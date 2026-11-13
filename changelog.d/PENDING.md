### Fixed

- A shutdown that hands a Keeper's admission to a successor operation moves
  the Owner and the intake fence together. When the intake fence named a
  third operation, the Owner used to move to the successor anyway, and no
  retry of the handoff could bring the two records back together. The Owner
  now stays put and the handoff fails until that fence is released; an Owner
  that refuses the handoff gets the fence put back (#PENDING).
