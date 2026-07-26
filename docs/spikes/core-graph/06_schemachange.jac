node Pantry { has title: str; has region: str = "midwest"; }

with entry:__main__ {
    if len([root -->[?:Pantry]]) == 0 { root ++> Pantry(title="Eastside"); }
    for p in [root -->[?:Pantry]] { print("pantry:", p.title, p.region); }
}
