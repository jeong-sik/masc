Fixed

Keeper-scoped approval audit reads now count actual matching records through the strict reverse reader, so unrelated Keeper traffic cannot hide durable history behind an estimated tail. Visited corruption remains explicit.
