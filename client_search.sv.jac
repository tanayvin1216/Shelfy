"""Backshelf - `MatchNeeds`, the client-facing shelf search (spec §6).

This is the ONLY endpoint a pantry client touches, and the only `walker:pub`
outside the seed. It answers one question: *of everything on the shelf right
now, what can I look at, given what I have to avoid?*

It is a real traversal, not a query. The walker starts at the household (or at
`root` with an anonymous pickup code), walks BACKWARD up the `Pantry --> Household`
edge to reach the pantry, fans out to every `Shelf`, crosses `Stocks` to reach
each `Item`, and reads that item's `Contains` edges to decide whether to offer
it. The pruning happens *as the walker moves*; there is no query language here
and no database underneath it.

    root ──▶ Pantry ──▶ Shelf ──Stocks──▶ Item ──Contains──▶ Allergen
              │                                                  ▲
              └──▶ Household ──Avoids───────────────────────────┘
                    (walker enters here, then `[here <--]` back up to Pantry)

Three prunes fire, in this order, and every prune is reported so the client can
see WHY something is not on their list:

  1. `not_cleared`         - §4: no item reaches the shelf without human clearance.
  2. `active_recall`       - §4: a CONFIRMED FlaggedBy edge blocks the item outright.
  3. `label_lists_avoided` - the item's label lists something this household avoids.

Constraints come from two places and are unioned: the durable `Avoids` edges
stored on the Household, plus whatever free text the person typed this visit
("allergic to peanuts, vegetarian, diabetic"), resolved to graph tag names by
`resolve_constraints`.

§4 privacy: a Household holds a pickup code, an opt-in contact and a language.
This walker reads the code and the language and reports them back to the person
who supplied the code. It never touches `notify_contact` and never puts it in a
report - the client search has no reason to know it exists.

§4 framing: nothing here says a food is safe. `explain_for_client` carries the
"the label lists / the label does not list" rule in its semstring, and the
report echoes a standing note saying the same thing in the UI's own voice.
"""

import from graph {
    Pantry, Shelf, Item, Allergen, Household,
    Stocks, Contains, Avoids, FlaggedBy,
    ItemView, AllergenTagView,
    _get_pantry, _find_household, _norm
}
import from llm {
    DateType, ItemForClient, explain_for_client, resolve_constraints
}

# ---------------------------------------------------------------------------
# Prune reasons - the closed vocabulary the UI switches on
# ---------------------------------------------------------------------------

glob WITHHELD_NOT_CLEARED: str = "not_cleared";
glob WITHHELD_ACTIVE_RECALL: str = "active_recall";
glob WITHHELD_LABEL_LISTS: str = "label_lists_avoided";

"""Standing framing note (§4). Not a prompt - it is UI copy, shown verbatim
next to the results so the page itself never implies a safety guarantee."""
glob CLIENT_FRAMING_NOTE: str =
    "This list is built from what each package's label lists. A package missing "
    "from your avoid list only means its label did not list it. Please read the "
    "label on the package before you use it.";

# ---------------------------------------------------------------------------
# Report shapes
# ---------------------------------------------------------------------------

obj ShelfMatch {
    """One item the client may take, with a plain-language note about its label."""
    has item: ItemView,
        explanation: str,
        matched_shelf: str;
}

obj WithheldItem {
    """One item held back, and the rule that held it back. Reported so the
    prune is visible rather than silent - a shelf that quietly shrinks is
    indistinguishable from a shelf that is empty."""
    has id: str,
        brand: str,
        product: str,
        reason: str,
        detail: str;
}

obj MatchReport {
    has pickup_code: str,
        household_found: bool,
        language: str,
        avoiding: list[str],
        avoids_stored: list[str],
        avoids_from_text: list[str],
        shelves_searched: list[str],
        items_considered: int,
        offered: list[ShelfMatch],
        withheld: list[WithheldItem],
        framing_note: str;
}

# ---------------------------------------------------------------------------
# Small helpers (underscore-prefixed: off the REST surface)
# ---------------------------------------------------------------------------

"""`Item.date_type` is a plain str on the node; `ItemForClient.date_type` is the
constrained enum byLLM reasons over. Anything unrecognised becomes UNKNOWN,
which is the §4-correct fallback: ambiguity routes to caution, never to a guess."""
def _as_date_type(raw: str) -> DateType {
    for d in DateType {
        if d.value == _norm(raw) {
            return d;
        }
    }
    return DateType.UNKNOWN;
}

"""Union of the two constraint sources, order-stable and de-duplicated."""
def _union_tags(stored: list[str], from_text: list[str]) -> list[str] {
    merged: list[str] = [];
    for t in stored + from_text {
        tag = _norm(t);
        if tag and tag not in merged {
            merged.append(tag);
        }
    }
    return merged;
}

# ---------------------------------------------------------------------------
# MatchNeeds
# ---------------------------------------------------------------------------

walker:pub MatchNeeds {
    """Filter the live shelf for one household. `POST /walker/MatchNeeds`.

    Two ways in, both landing in the same `Household entry`:
      * spawn on the Household node directly (`_jac_spawn_node`), or
      * spawn on `root` with `pickup_code` - the lookup-base pattern, which is
        what the client screen does because a pickup code is all the person has.

    An unknown or empty pickup code is NOT an error: the walker skips the
    household stage and browses the shelf anonymously against whatever free
    text was typed. That is the walk-up case, and it is the one that must not
    require an account.
    """

    # --- request ---
    has pickup_code: str = "";
    has constraints_text: str = "";
    has language: str = "";

    # --- traversal state ---
    has resolved: bool = False;
    has household_found: bool = False;
    has code_seen: str = "";
    has avoids_stored: list[str] = [];
    has avoids_from_text: list[str] = [];
    has avoiding: list[str] = [];
    has shelves_searched: list[str] = [];
    has items_considered: int = 0;
    has offered: list[ShelfMatch] = [];
    has withheld: list[WithheldItem] = [];

    has reports: list[MatchReport] = [];

    # --- 1. locate: pickup code -> Household, else browse anonymously ---
    can locate with Root entry {
        if self.resolved {
            skip;
        }
        self.resolved = True;

        code = self.pickup_code.strip();
        self.code_seen = code;
        if code {
            hh = _find_household(code);
            if hh is not None {
                self.household_found = True;
                visit [hh];
                skip;
            }
        }
        visit [_get_pantry()];
    }

    # --- 2. read this household's durable Avoids edges ---
    can read_needs with Household entry {
        self.household_found = True;
        self.code_seen = here.pickup_code;
        if not self.language {
            self.language = here.preferred_language;
        }
        # §4: pickup_code and preferred_language only. `notify_contact` is never read.
        self.avoids_stored = [_norm(a.name) for a in [here ->:Avoids:->]];

        # BACKWARD along Pantry --> Household to reach the pantry that holds the
        # shelves. The `else` covers a Household reached by an arbitrary
        # `_jac_spawn_node` that is not wired to a pantry - without it the
        # traversal would end before `Pantry exit` and the caller would get zero
        # reports instead of an empty shelf.
        visit [here <--[?:Pantry]] else {
            visit [_get_pantry()];
        }
    }

    # --- 3. resolve free text, then fan out over every shelf ---
    can pick_shelves with Pantry entry {
        if not self.language {
            self.language = "en";
        }
        typed = self.constraints_text.strip();
        if typed {
            self.avoids_from_text = resolve_constraints(typed);
        }
        self.avoiding = _union_tags(self.avoids_stored, self.avoids_from_text);

        visit [here -->[?:Shelf]];
    }

    # --- 4. cross Stocks, prune, explain ---
    can gather with Shelf entry {
        self.shelves_searched.append(here.name);

        for it in [here ->:Stocks:->] {
            self.items_considered += 1;
            view = it.to_view();

            if not it.cleared {
                self.hold(view, WITHHELD_NOT_CLEARED,
                          "waiting for a volunteer to check it over");
                continue;
            }

            if view.has_confirmed_recall {
                self.hold(view, WITHHELD_ACTIVE_RECALL,
                          "pulled from the shelf, this batch is under an active recall");
                continue;
            }

            hits = [t.name for t in view.allergens if _norm(t.name) in self.avoiding];
            if hits {
                self.hold(view, WITHHELD_LABEL_LISTS,
                          "the label lists " + ", ".join(hits));
                continue;
            }

            self.offered.append(ShelfMatch(
                item=view,
                explanation=explain_for_client(
                    item=self.as_client_item(it, view),
                    constraints=self.avoiding,
                    language=self.language
                ),
                matched_shelf=here.name
            ));
        }
    }

    # --- 5. the Pantry's exit runs after every shelf below it: report once ---
    can finish with Pantry exit {
        report MatchReport(
            pickup_code=self.code_seen,
            household_found=self.household_found,
            language=self.language,
            avoiding=self.avoiding,
            avoids_stored=self.avoids_stored,
            avoids_from_text=self.avoids_from_text,
            shelves_searched=self.shelves_searched,
            items_considered=self.items_considered,
            offered=self.offered,
            withheld=self.withheld,
            framing_note=CLIENT_FRAMING_NOTE
        );
    }

    # --- helpers on the walker ---

    def hold(view: ItemView, reason: str, detail: str) {
        self.withheld.append(WithheldItem(
            id=view.id,
            brand=view.brand,
            product=view.product,
            reason=reason,
            detail=detail
        ));
    }

    """Project a graph Item into the flat obj `explain_for_client` reasons over.
    `allergens_listed` comes from the item's own `Contains` edges, so the note
    can only talk about what THIS package's label actually declared."""
    def as_client_item(it: Item, view: ItemView) -> ItemForClient {
        return ItemForClient(
            brand=it.brand,
            product=it.product,
            category=it.category,
            date_value=it.date_value,
            date_type=_as_date_type(it.date_type),
            allergens_listed=[t.name for t in view.allergens],
            ingredients_text=it.ingredients_text,
            shelf_life_note=(it.verdict_reason if it.verdict == "review" else "")
        );
    }
}
