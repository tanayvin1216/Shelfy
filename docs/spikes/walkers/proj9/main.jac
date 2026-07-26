obj S { has n: int = 0; def double -> int; }
with entry { print(S(n=3).double()); }
