node A { has t: str = "a"; }
node B { has t: str = "b"; }
edge R: A --> B { has c: str = "r"; }
with entry:__main__ {
    a = A(); b = B(); root ++> a; root ++> b;
    a +>:R(c="r1"):+> b;
    print("edges before:", len([edge a ->:R:-> b]));
    del [a ->:R:-> b];
    print("edges after :", len([edge a ->:R:-> b]));
}
