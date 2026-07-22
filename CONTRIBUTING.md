# Contributing

Every change follows SPEC → RED TEST/CONTROL → IMPLEMENTATION → REVIEW.

A Crystal must keep dependency direction one-way, use only Uruquim's public
surface, state ownership/capacity/threading/failure, inventory its exported
symbols, compile its example and include a negative control capable of making
the gate fail. No package may require a core change as a condition of landing.

Fundamental APIs use conventional names. SQL packages use `execute`, `query`,
`begin`, `commit` and `rollback`; the ecosystem does not make a user translate
metaphors before doing ordinary work.
