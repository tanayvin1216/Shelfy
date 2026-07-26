"""Recall fan-out: duplicates, dedupe, jid/jobj lookup, assign-comprehension, printgraph."""

node Pantry     { has name: str; }
node Item       { has sku: str; has name: str; has lot: str = ""; has recalled: bool = False; }
node Household  { has family: str; has notified: bool = False; }
node RecallRecord { has recall_id: str; has severity: int = 1; }

edge Received:  Household --> Item { has pickup_code: str; }
edge FlaggedBy: Item --> RecallRecord { has confidence: float = 0.5; }

with entry:__main__ {
    p = Pantry(name="Eastside");
    root ++> p;

    pb  = Item(sku="PB-100", name="Peanut Butter", lot="L77");
    pb2 = Item(sku="PB-100", name="Peanut Butter", lot="L78");
    rice = Item(sku="RC-300", name="Rice");
    for i in [pb, pb2, rice] { root ++> i; }

    lopez = Household(family="Lopez");
    chen  = Household(family="Chen");
    p ++> lopez; p ++> chen;

    # Lopez received BOTH recalled lots -> would appear twice
    lopez +>:Received(pickup_code="PU-001"):+> pb;
    lopez +>:Received(pickup_code="PU-002"):+> pb2;
    chen  +>:Received(pickup_code="PU-003"):+> pb;
    chen  +>:Received(pickup_code="PU-004"):+> rice;

    rec = RecallRecord(recall_id="FDA-2026-441", severity=3);
    root ++> rec;
    pb  +>:FlaggedBy(confidence=0.95):+> rec;
    pb2 +>:FlaggedBy(confidence=0.80):+> rec;

    print("=== raw two-hop backward (DUPLICATES) ===");
    raw = [rec <-:FlaggedBy:<- <-:Received:<-];
    print([h.family for h in raw], "len:", len(raw));

    print("=== deduped by identity ===");
    seen: list[Household] = [];
    for h in raw { if h not in seen { seen.append(h); } }
    print([h.family for h in seen], "len:", len(seen));

    print("=== dedupe via jid set (stable across walkers) ===");
    ids: set[str] = set();
    uniq: list[Household] = [];
    for h in raw {
        k = jid(h);
        if k not in ids { ids.add(k); uniq.append(h); }
    }
    print([h.family for h in uniq]);

    print("=== high-confidence only: filter the FlaggedBy edge attr ===");
    hi = [rec <-:FlaggedBy:confidence >= 0.9:<- <-:Received:<-];
    print([h.family for h in hi]);

    print("=== notification payload: household + pickup codes ===");
    for itm in [rec <-:FlaggedBy:<-] {
        for e in [edge itm <-:Received:<-] {
            print(f"  {itm.sku}/{itm.lot} lot -> {e.pickup_code}");
        }
    }

    print("=== assign comprehension: bulk mark ===");
    [rec <-:FlaggedBy:<-](=recalled=True);
    print("items recalled flags:", [(i.sku, i.lot, i.recalled) for i in [root -->[?:Item]]]);
    uniq(=notified=True);
    print("household notified:", [(h.family, h.notified) for h in [p -->[?:Household]]]);

    print("=== jid / jobj round trip (find-by-id) ===");
    rid = jid(rec);
    print("recall jid:", rid);
    back = jobj(rid);
    print("jobj type:", type(back).__name__);
    if isinstance(back, RecallRecord) { print("recovered recall_id:", back.recall_id); }

    print("=== printgraph (first 200 chars of DOT) ===");
    print(printgraph(root)[:200]);
}
