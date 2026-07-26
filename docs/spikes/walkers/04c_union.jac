node Dog { has name: str; }
node Cat { has lives: int = 9; }

walker Vet {
    has reports: list[str] = [];
    can start with Root entry { visit [-->]; }
    can checkup with Dog | Cat entry {
        if isinstance(here, Dog) { report f"dog {here.name}"; }
        elif isinstance(here, Cat) { report f"cat {here.lives}"; }
    }
}

walker Vet2 {                       # separate ability per node type
    has reports: list[str] = [];
    can start with Root entry { visit [-->]; }
    can d with Dog entry { report f"dog {here.name}"; }
    can c with Cat entry { report f"cat {here.lives}"; }
}

with entry {
    root ++> Dog(name="rex");
    root ++> Cat(lives=7);
    print("UNION+isinstance:", (root spawn Vet()).reports);
    print("PER-TYPE        :", (root spawn Vet2()).reports);
}
