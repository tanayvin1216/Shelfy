node Base { has name: str = "?"; }
node Child(Base) { has code: str; }
with entry:__main__ { print(Child(code="c")); }
