"""Does node-reference traversal dedupe? Single-hop parallel edges + multi-hop diamonds."""

node A { has tag: str; }
node B { has tag: str; }
node C { has tag: str; }

edge R: A --> B { has code: str; }
edge S: B --> C { has code: str; }

with entry:__main__ {
    a = A(tag="a"); root ++> a;
    b = B(tag="b"); root ++> b;
    c = C(tag="c"); root ++> c;

    # TWO parallel R edges a->b
    a +>:R(code="r1"):+> b;
    a +>:R(code="r2"):+> b;

    print("single-hop node read  [a ->:R:->] :", [n.tag for n in [a ->:R:->]]);
    print("single-hop edge read  [edge ...]  :", [e.code for e in [edge a ->:R:->]]);

    b +>:S(code="s1"):+> c;
    b +>:S(code="s2"):+> c;
    print("two-hop node read [a ->:R:-> ->:S:->]:", [n.tag for n in [a ->:R:-> ->:S:->]]);

    # diamond: c <- b1, c <- b2 ; both b's <- a
    b1 = B(tag="b1"); b2 = B(tag="b2");
    root ++> b1; root ++> b2;
    a +>:R(code="x"):+> b1;
    a +>:R(code="y"):+> b2;
    c2 = C(tag="c2"); root ++> c2;
    b1 +>:S(code="p"):+> c2;
    b2 +>:S(code="q"):+> c2;

    print("diamond forward  :", [n.tag for n in [a ->:R:-> ->:S:->]]);
    print("diamond BACKWARD :", [n.tag for n in [c2 <-:S:<- <-:R:<-]]);
    print("backward edges   :", [e.code for e in [edge c2 <-:S:<-]]);
}
