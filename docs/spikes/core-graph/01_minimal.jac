import from datetime { datetime }

glob APP_NAME: str = "Backshelf";

def label_for(count: int) -> str {
    return "empty" if count == 0 else f"{count} items";
}

obj Config {
    has name: str;
    has debug: bool = False;
}

with entry {
    cfg = Config(name=APP_NAME);
    print(cfg.name, cfg.debug);
    print(label_for(0), label_for(3));
    print(type(datetime.now()).__name__);
}
