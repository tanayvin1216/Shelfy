"""Backshelf - demo seed data (spec section 10, "demo seed data").

`SeedPantry` builds the empty skeleton: one Pantry, two shelves, the RecallFeed
and the Allergen vocabulary. That is all a fresh install needs, and it is
deliberately free of made-up inventory.

This module adds the ONE thing the stage demo needs on top of that skeleton:
distribution history. `RecallSweep`'s backward traversal can only name a
household if some household actually took an item home, and no walker on the
REST surface creates a `Received` edge - intake stops at the shelf.

The scenario is Maria (spec section 2), built against the real openFDA record
H-1125-2026 (Class I, undeclared peanuts, Western Mixers / FIRST STREET Dark
Chocolate Raisins, `Lot: 260562 BB: 022527`):

    lot 260562   on the shelf, handed to pickup codes 4471 and 8830
                 -> CONFIRMED once the sweep runs. Both households get named.
    lot 991234   same brand and product, legible, NOT in the recall
                 -> WEAK. Informational. This is the fix to v1's Flaw 2.
    lot (none)   smudged, handed to 2210
                 -> POSSIBLE. Review, surface the codes, notify the household.
    green beans  no flag at all - the sweep is not just flagging everything.

Idempotent, like `SeedPantry`: items are keyed on brand+product+lot and
`Received` edges are checked before they are written, so re-running this walker
against a live graph creates nothing and reports `created=0`.
"""

import from graph {
    Pantry, Item, Household, Shelf,
    Received, Stocks, Avoids,
    SHELF_CANNED,
    _get_pantry, _get_shelf, _get_household, _get_allergen, _now
}

glob DEMO_BRAND: str = "FIRST STREET";
glob DEMO_PRODUCT: str = "Dark Chocolate Raisins 9 oz";

obj DemoHandout {
    has pickup_code: str,
        item_id: str,
        product: str,
        lot_code: str,
        preferred_language: str;
}

obj DemoReport {
    has created: int,
        already_seeded: bool,
        confirmed_item_id: str,
        possible_item_id: str,
        weak_item_id: str,
        clean_item_id: str,
        handouts: list[DemoHandout],
        households: list[str],
        note: str;
}

# ---------------------------------------------------------------------------
# Helpers - underscore-prefixed so they stay off the REST surface
# ---------------------------------------------------------------------------

"""Get-or-create an Item on a shelf, keyed on brand + product + lot."""
def _find_stocked(shelf: Shelf, brand: str, product: str, lot: str) -> Item | None {
    for existing in [shelf ->:Stocks:->] {
        if existing.brand == brand
           and existing.product == product
           and existing.lot_code == lot {
            return existing;
        }
    }
    return None;
}

def _stock(shelf: Shelf, brand: str, product: str, lot: str, note: str) -> Item {
    hit = _find_stocked(shelf, brand, product, lot);
    if hit is not None {
        return hit;
    }
    return (shelf +>:Stocks:+> Item(
        brand=brand,
        product=product,
        category="snack_food",
        ingredients_text="dark chocolate, raisins",
        date_value="BB 022527",
        date_type="best_by",
        lot_code=lot,
        packaging_note="intact",
        extraction_confidence=0.9,
        legibility_note=note,
        verdict="keep",
        verdict_reason="cleared at intake before the recall was announced",
        cleared=True,
        scanned_at=_now()
    ))[0] as Item;
}

"""Hand an item to a household. `Received` points Household --> Item; the
sweep walks it in reverse, which is the whole point of the project."""
def _hand_out(code: str, item: Item, language: str, contact: str, at: str) -> bool {
    household = _get_household(code);
    household.preferred_language = language;
    household.notify_contact = contact;
    for _existing in [edge household ->:Received:-> item] {
        return False;
    }
    household +>:Received(pickup_code=code, timestamp=at):+> item;
    return True;
}

def _avoid(code: str, allergen: str) -> bool {
    household = _get_household(code);
    target = _get_allergen(allergen);
    for _existing in [edge household ->:Avoids:-> target] {
        return False;
    }
    household +>:Avoids:+> target;
    return True;
}

# ---------------------------------------------------------------------------
# SeedDemo
# ---------------------------------------------------------------------------

walker:pub SeedDemo {
    """Lay the Maria scenario over an already-seeded pantry.

    Run `SeedPantry` first. This walker only writes inventory and distribution
    history; it does not create flags. `RecallSweep` creates those, which is
    the honest ordering - the recall is announced after the food went out.
    """

    has created: int = 0;
    has resolved: bool = False;
    has handouts: list[DemoHandout] = [];
    has reports: list[DemoReport] = [];

    can build with Root entry {
        if self.resolved {
            skip;
        }
        self.resolved = True;
        visit [_get_pantry()];
    }

    can populate with Pantry entry {
        canned = _get_shelf(SHELF_CANNED);

        confirmed = self.stock(canned, DEMO_BRAND, DEMO_PRODUCT, "260562", "lot code sharp");
        possible = self.stock(canned, DEMO_BRAND, DEMO_PRODUCT, "", "lot code smudged");
        weak = self.stock(canned, DEMO_BRAND, DEMO_PRODUCT, "991234", "lot code sharp");
        clean = self.stock(canned, "DEL MONTE", "Cut Green Beans 14.5 oz", "P8241", "clean");

        self.handout("4471", confirmed, "en", "opted in: sms", "2026-07-18T10:20:00");
        self.handout("8830", confirmed, "es", "", "2026-07-18T11:05:00");
        self.handout("2210", possible, "en", "", "2026-07-19T09:40:00");

        # 8830 told the volunteer about a peanut allergy at pickup. MatchNeeds
        # reads this edge; the household node still holds no PII.
        if _avoid("8830", "peanuts") {
            self.created += 1;
        }

        report DemoReport(
            created=self.created,
            already_seeded=(self.created == 0),
            confirmed_item_id=jid(confirmed),
            possible_item_id=jid(possible),
            weak_item_id=jid(weak),
            clean_item_id=jid(clean),
            handouts=self.handouts,
            households=[h.pickup_code for h in [here --> [?:Household]]],
            note=(
                "Distribution history only. No FlaggedBy edges exist yet - run "
                "RecallSweep to announce the recall and watch it walk backwards "
                "to the pickup codes."
            )
        );
        disengage;
    }

    def stock(shelf: Shelf, brand: str, product: str, lot: str, note: str) -> Item {
        if _find_stocked(shelf, brand, product, lot) is None {
            self.created += 1;
        }
        return _stock(shelf, brand, product, lot, note);
    }

    def handout(code: str, item: Item, language: str, contact: str, at: str) {
        if _hand_out(code, item, language, contact, at) {
            self.created += 1;
        }
        self.handouts.append(DemoHandout(
            pickup_code=code,
            item_id=jid(item),
            product=f"{item.brand} {item.product}",
            lot_code=item.lot_code,
            preferred_language=language
        ));
    }
}
