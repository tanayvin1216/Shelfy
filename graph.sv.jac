"""Backshelf - the pantry graph (spec section 5).

The graph IS the database. Every node here is persisted purely by being
reachable from `root`; there is no ORM, no schema migration, no store layer.

Layout:

    root
     +-> Pantry
          +-> Shelf --Stocks--> Item --Contains--> Allergen
          |                       +--FlaggedBy--> RecallRecord
          +-> Household --Avoids--> Allergen
          |        +--Received--> Item
          +-> RecallFeed --Lists--> RecallRecord
          +-> Allergen (the seeded vocabulary hangs off the Pantry so it is
                        reachable without walking through an Item)

Helper defs are underscore-prefixed so they stay off the REST surface; the only
public endpoint in this module is the `SeedPantry` walker.
"""

import from datetime { datetime }

# ---------------------------------------------------------------------------
# Seed vocabulary
# ---------------------------------------------------------------------------

glob DEFAULT_PANTRY_NAME: str = "Backshelf Community Pantry";
glob SHELF_CANNED: str = "canned goods";
glob SHELF_REVIEW: str = "review queue";
glob SEED_SHELVES: list[str] = [SHELF_CANNED, SHELF_REVIEW];

"""FDA big 9 major food allergens."""
glob BIG_NINE: list[str] = [
    "milk", "eggs", "fish", "shellfish", "tree nuts",
    "peanuts", "wheat", "soybeans", "sesame"
];

"""Non-allergen dietary tags carried as Allergen nodes: religious restrictions
and diabetic filtering both work off the same Avoids/Contains edges."""
glob DIETARY_TAGS: list[str] = [
    "pork", "beef", "gelatin", "alcohol", "added sugar"
];

glob SEED_ALLERGENS: list[str] = BIG_NINE + DIETARY_TAGS;

"""Recall confidence tiers (spec section 4). CONFIRMED blocks clearance."""
glob CONFIRMED: str = "CONFIRMED";
glob POSSIBLE: str = "POSSIBLE";
glob WEAK: str = "WEAK";

# ---------------------------------------------------------------------------
# Nodes
# ---------------------------------------------------------------------------

node Pantry {
    has name: str = DEFAULT_PANTRY_NAME,
        created_at: str = "";
}

node Shelf {
    has name: str;
}

node Allergen {
    """FDA big 9 plus dietary tags. `name` is stored normalized (lower, trimmed)."""
    has name: str;
}

node Household {
    """No PII, by design. Identity is the anonymous 4-digit pickup code."""
    has pickup_code: str,
        notify_contact: str = "",
        preferred_language: str = "en";
}

node RecallFeed {
    has last_synced: str = "";
}

node RecallRecord {
    has recall_number: str,
        recalling_firm: str = "",
        product_description: str = "",
        reason: str = "",
        classification: str = "",
        code_info: str = "",
        distribution_pattern: str = "",
        status: str = "",
        report_date: str = "";
}

node Item {
    has brand: str = "",
        product: str = "",
        category: str = "",
        ingredients_text: str = "",
        date_value: str = "",
        date_type: str = "unknown",
        lot_code: str = "",
        packaging_note: str = "",
        extraction_confidence: float = 0.0,
        legibility_note: str = "",
        verdict: str = "review",
        verdict_reason: str = "",
        cleared: bool = False,
        scanned_at: str = "";

    def to_view -> ItemView;
}

# ---------------------------------------------------------------------------
# Edges (typed endpoints so every traversal infers its node type)
# ---------------------------------------------------------------------------

edge Stocks: Shelf --> Item {}

edge Contains: Item --> Allergen {
    """`evidence` = the ingredient words that justified the tag."""
    has evidence: str = "";
}

edge FlaggedBy: Item --> RecallRecord {
    has confidence: str = WEAK,
        matched_fields: str = "";
}

edge Avoids: Household --> Allergen {}

edge Received: Household --> Item {
    has pickup_code: str = "",
        timestamp: str = "";
}

edge Lists: RecallFeed --> RecallRecord {}

# ---------------------------------------------------------------------------
# View models - walkers report these, never raw nodes
# ---------------------------------------------------------------------------

obj AllergenTagView {
    has name: str,
        evidence: str;
}

obj RecallFlagView {
    has recall_number: str,
        confidence: str,
        matched_fields: str,
        reason: str,
        classification: str,
        code_info: str;
}

obj ItemView {
    has id: str,
        brand: str,
        product: str,
        category: str,
        ingredients_text: str,
        date_value: str,
        date_type: str,
        lot_code: str,
        packaging_note: str,
        extraction_confidence: float,
        legibility_note: str,
        verdict: str,
        verdict_reason: str,
        cleared: bool,
        scanned_at: str,
        shelf: str,
        allergens: list[AllergenTagView],
        recall_flags: list[RecallFlagView],
        has_confirmed_recall: bool;
}

impl Item.to_view -> ItemView {
    tags: list[AllergenTagView] = [];
    for a in [self ->:Contains:->] {
        for e in [edge self ->:Contains:-> a] {
            tags.append(AllergenTagView(name=a.name, evidence=e.evidence));
        }
    }

    flags: list[RecallFlagView] = [];
    blocked = False;
    for r in [self ->:FlaggedBy:->] {
        for e in [edge self ->:FlaggedBy:-> r] {
            if e.confidence == CONFIRMED {
                blocked = True;
            }
            flags.append(RecallFlagView(
                recall_number=r.recall_number,
                confidence=e.confidence,
                matched_fields=e.matched_fields,
                reason=r.reason,
                classification=r.classification,
                code_info=r.code_info
            ));
        }
    }

    holders = [self <-:Stocks:<-];
    return ItemView(
        id=jid(self),
        brand=self.brand,
        product=self.product,
        category=self.category,
        ingredients_text=self.ingredients_text,
        date_value=self.date_value,
        date_type=self.date_type,
        lot_code=self.lot_code,
        packaging_note=self.packaging_note,
        extraction_confidence=self.extraction_confidence,
        legibility_note=self.legibility_note,
        verdict=self.verdict,
        verdict_reason=self.verdict_reason,
        cleared=self.cleared,
        scanned_at=self.scanned_at,
        shelf=(holders[0].name if len(holders) > 0 else ""),
        allergens=tags,
        recall_flags=flags,
        has_confirmed_recall=blocked
    );
}

obj SeedReport {
    has pantry_id: str,
        pantry_name: str,
        shelves: list[str],
        allergens: list[str],
        recall_feed_id: str,
        nodes_created: int,
        already_seeded: bool;
}

# ---------------------------------------------------------------------------
# Helpers - lookups and create-if-missing upserts
# ---------------------------------------------------------------------------

def _now() -> str {
    return datetime.now().isoformat(timespec="seconds");
}

def _norm(name: str) -> str {
    return name.strip().lower();
}

"""The single pantry hanging off root, if it has been seeded."""
def _find_pantry() -> Pantry | None {
    for p in [root --> [?:Pantry]] {
        return p;
    }
    return None;
}

"""Idempotent: matches on presence, not on name, so a re-seed under a
different display name still resolves to the one existing Pantry."""
def _get_pantry() -> Pantry {
    hit = _find_pantry();
    if hit is not None {
        return hit;
    }
    return (root ++> Pantry(name=DEFAULT_PANTRY_NAME, created_at=_now()))[0] as Pantry;
}

def _find_shelf(name: str) -> Shelf | None {
    wanted = _norm(name);
    for s in [_get_pantry() --> [?:Shelf]] {
        if _norm(s.name) == wanted {
            return s;
        }
    }
    return None;
}

def _get_shelf(name: str) -> Shelf {
    hit = _find_shelf(name);
    if hit is not None {
        return hit;
    }
    return (_get_pantry() ++> Shelf(name=_norm(name)))[0] as Shelf;
}

def _review_shelf() -> Shelf {
    return _get_shelf(SHELF_REVIEW);
}

def _get_recall_feed() -> RecallFeed {
    p = _get_pantry();
    for f in [p --> [?:RecallFeed]] {
        return f;
    }
    return (p ++> RecallFeed(last_synced=""))[0] as RecallFeed;
}

def _find_allergen(name: str) -> Allergen | None {
    wanted = _norm(name);
    for a in [_get_pantry() --> [?:Allergen]] {
        if a.name == wanted {
            return a;
        }
    }
    return None;
}

"""Allergen-by-name, create-if-missing. Names are normalized so 'Tree Nuts'
and 'tree nuts ' resolve to the same node instead of forking it."""
def _get_allergen(name: str) -> Allergen {
    hit = _find_allergen(name);
    if hit is not None {
        return hit;
    }
    return (_get_pantry() ++> Allergen(name=_norm(name)))[0] as Allergen;
}

def _all_allergens() -> list[Allergen] {
    return [_get_pantry() --> [?:Allergen]];
}

def _find_household(pickup_code: str) -> Household | None {
    for h in [_get_pantry() --> [?:Household]] {
        if h.pickup_code == pickup_code {
            return h;
        }
    }
    return None;
}

def _get_household(pickup_code: str) -> Household {
    hit = _find_household(pickup_code);
    if hit is not None {
        return hit;
    }
    return (_get_pantry() ++> Household(pickup_code=pickup_code))[0] as Household;
}

"""Dedupe hook for RecallSweep: a re-sync must update, not re-create."""
def _find_recall_record(recall_number: str) -> RecallRecord | None {
    for r in [_get_recall_feed() ->:Lists:->] {
        if r.recall_number == recall_number {
            return r;
        }
    }
    return None;
}

def _shelf_items(name: str) -> list[Item] {
    return [_get_shelf(name) ->:Stocks:->];
}

# ---------------------------------------------------------------------------
# SeedPantry - idempotent
# ---------------------------------------------------------------------------

walker:pub SeedPantry {
    """Stand up the pantry skeleton: one Pantry, the two shelves, the RecallFeed
    and the full Allergen vocabulary.

    Running it twice must not fork the graph. Every step goes through a
    create-if-missing helper, and `nodes_created` reports 0 on a re-run - that
    counter is the idempotency proof, not a comment claiming idempotency.
    """

    has pantry_name: str = DEFAULT_PANTRY_NAME;
    has created: int = 0;
    has reports: list[SeedReport] = [];

    can enter_pantry with Root entry {
        visit [here --> [?:Pantry]] else {
            fresh = here ++> Pantry(name=self.pantry_name, created_at=_now());
            self.created += 1;
            visit fresh;
        }
    }

    can furnish with Pantry entry {
        for name in SEED_SHELVES {
            if _find_shelf(name) is None {
                self.created += 1;
            }
            _get_shelf(name);
        }

        if len([here --> [?:RecallFeed]]) == 0 {
            self.created += 1;
        }
        feed = _get_recall_feed();

        for name in SEED_ALLERGENS {
            if _find_allergen(name) is None {
                self.created += 1;
            }
            _get_allergen(name);
        }

        report SeedReport(
            pantry_id=jid(here),
            pantry_name=here.name,
            shelves=[s.name for s in [here --> [?:Shelf]]],
            allergens=[a.name for a in [here --> [?:Allergen]]],
            recall_feed_id=jid(feed),
            nodes_created=self.created,
            already_seeded=(self.created == 0)
        );
        disengage;
    }
}
