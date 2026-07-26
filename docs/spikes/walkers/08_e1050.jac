node L { has c: str; }
walker W { has reports: list[str]; can go with Root entry { report "x"; } }
with entry { print((root spawn W()).reports); }
