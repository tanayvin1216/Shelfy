node Dog { has name: str; }
node Cat { has lives: int = 9; }

walker Vet {
    has reports: list[str] = [];
    can start with Root entry { visit [-->]; }
    can checkup with Dog | Cat entry {
        ->Dog { report f"dog {here.name}"; }
        ->Cat { report f"cat {here.lives}"; }
    }
}

with entry {
    root ++> Dog(name="rex");
    root ++> Cat(lives=7);
    print((root spawn Vet()).reports);
}
