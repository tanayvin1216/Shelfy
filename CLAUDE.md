# Backshelf

**A food pantry intake and recall-propagation system, built in Jac.**

Hackathon: JacHacks SF 2026, Founders Inc, Fort Mason. Hacking window 10:45 AM – 7:15 PM, one day.
Submissions close 7:15 PM hard. Partial submission required at 5:50 PM.

---

## 0. How to use this file

You are building this project autonomously. This document is the complete spec.
Read all of it before writing code.

Priority order when something is ambiguous:

1. Domain safety rules (§4) — never violate these, they are the point of the project
2. Jac depth (§2) — 40% of the score, double any other criterion
3. A working end-to-end demo (§9) — a running product beats a bigger unfinished one
4. Everything else

If you are about to do something that trades away #1 or #2 for #3, stop and ask.

---

## 1. Critical: this is Jac, not Python

**Read the docs before writing a single line.** Your training data on Jac is thin
and probably stale. Do not guess syntax from Python intuition — Jac looks
Python-adjacent and is semantically different.

Fetch and read these first:

- https://github.com/jaseci-labs/jac — README, current syntax overview
- https://docs.jaseci.org/learn/data_spatial/nodes_and_edges/
- https://docs.jaseci.org/learn/data_spatial/walkers/
- https://docs.jaseci.org/learn/jac-byllm/
- https://docs.jaseci.org/learn/jac-byllm/agentic_ai/
- https://docs.jaseci.org/tutorials/fullstack/setup/ — `.cl.jac` frontend
- https://docs.jaseci.org/reference/cli/ — `jac start`, `jac build --client web`

Check whether the `jac-mcp` plugin is installed (`pip show jac-mcp`). If it is,
prefer it for syntax questions over guessing.

### Hard rules

- **Never route around Jac by writing Python.** If a `jac` command errors, read
  the error and consult the docs. Falling back to Python destroys the score.
- **The frontend is Jac too.** Use `.cl.jac` files. Do not reach for React/Next
  unless the fallback in §7 is formally triggered.
- **No manual prompt strings.** LLM calls go through `by llm()` with `sem`
  annotations. Writing an f-string prompt and calling an SDK directly is the
  single most damaging thing you could do to this project's score.
- **No database code.** Persistence in Jac is reachability from `root`. If you
  find yourself writing SQL, an ORM, or a JSON file store, you have taken a
  wrong turn.

### Constructs we are using deliberately

| Construct | Where |
|---|---|
| `node` / `edge` | Domain model (§5) |
| `walker` + `can <ability> with <NodeType> entry` | All business logic |
| `visit`, `disengage` | Traversal, including the backward sweep |
| `by llm()` | Label extraction, shelf-life reasoning, client explanations |
| `sem` | Carrying domain context into byLLM without prompt strings |
| Root reachability | Persistence — no DB layer |
| `.cl.jac` | Frontend components |
| `walker:pub` | Public endpoints (client-facing search only) |

Walkers auto-generate `POST /walker/<Name>`. That is our API. Do not hand-write
REST routes.

---

## 2. The problem

There are roughly 60,000 food pantries in the US. Most run on volunteers and
clipboards with no inventory system. Donations arrive unsorted, unbarcoded, and
undated.

A grocery shopper gets recall alerts and clear labels for free. A family picking
up food from a pantry shelf gets neither. The people this hurts most are the ones
who can least afford a mistake — a parent of a child with a peanut allergy,
someone managing diabetes, a senior with a religious dietary restriction.

**The specific gap this project targets:**

A recall announced on Tuesday affects the can that went out the door on Saturday.

Current food bank practice for recalls is to brief volunteers, post notices in
sorting areas, and email partner sites. That protects food still in the building.
Nobody can tell a *specific household* that the jar in their cupboard is now
recalled. And pantry clients cannot simply go buy a replacement — they may wait
weeks for a comparable item.

That "last mile" of the recall system is the unsolved problem. It is unsolved
because nobody keeps a graph connecting recalls to items to the households that
received them. We are going to keep that graph.

### Name one person

Maria picks up groceries on Saturday. On Tuesday, FDA announces a Class I recall
on the brand of peanut butter she took home for her kids. Today, nothing tells
her. Backshelf tells her.

---

## 3. What this replaces, and what was wrong with it

This is a Jac rebuild of my earlier prototype (Shelfy — React Native + Gemini +
SQLite, scanned donations at intake for recalls, expiry, and allergens).

Put a line in the README acknowledging it is a rebuild of my own earlier
prototype. It strengthens the pitch: I shipped v1, found two design flaws, and
rebuilt it properly.

**Three things v1 got wrong. Fixing them is most of the value of v2.**

### Flaw 1 — "expired → discard" was backwards

v1 routed past-date items to discard. This is wrong and actively harmful.

Except for infant formula and baby food, date labels are **not** federally
regulated and are **not** safety dates. "Best by" and "sell by" indicate peak
quality. Food banks routinely and deliberately distribute past-code shelf-stable
food; many publish shelf-life guides precisely because they do. Date-label
confusion drives an estimated 20% of household food waste.

So v1's core routing rule destroyed edible food at organizations that are
chronically supply-constrained. It made the waste problem worse while solving the
recall problem.

**v2:** past-date shelf-stable goods route to REVIEW with shelf-life guidance,
never to discard. See §4.

### Flaw 2 — brand-only recall matching

v1 matched recalls on brand alone. Recalls are lot- and date-code specific. A
Jif recall would flag every jar of Jif in the building. v1 called this
"conservative," but conservative toward recalls is aggressive toward the food
supply, and false positives here destroy scarce food.

**v2:** lot-aware matching with explicit confidence tiers. Surface the recall's
actual lot codes next to the scanned code and let a human compare. Never
auto-discard on a brand match. See §4.

### Flaw 3 — intake-time checking only

v1 checked recalls when an item arrived. That protects nothing already
distributed, which is where the real harm is. It also made the project a
recombination of things that already exist — AI label scanners, pantry inventory
software, and openFDA are all off-the-shelf.

**v2:** the retroactive recall sweep (§6, `RecallSweep`). This is the novel
contribution and the demo money shot.

---

## 4. Domain rules — non-negotiable

These are the product. Violating them to ship faster defeats the purpose.

### Shelf life and dates

- **NEVER** route an item to DISCARD based on a past date alone.
- Past-date shelf-stable goods → **REVIEW**, with a shelf-life note explaining
  the typical safe window past code for that category.
- Items that **DO** discard regardless of anything else:
  - Infant formula or baby food past its date (the one federally regulated
    category)
  - Visibly compromised packaging: dented seams, bulging, rust, punctures,
    broken safety seals
  - Past-date perishables (dairy, fresh meat, produce)
  - Home-canned or unlabeled homemade goods (pantries cannot accept these)
- If the date is unreadable or the date type is ambiguous → REVIEW, never discard.

**Reference shelf-life windows past code date** (use these in the `sem`
annotation for `shelf_life_verdict` — they come from published food bank guides):

| Category | Typical window past code |
|---|---|
| Canned low-acid (vegetables, meat, soup, beans) | 2–5 years |
| Canned high-acid (tomatoes, citrus, fruit, pickles) | 12–18 months |
| Dry pasta, white rice | 2+ years |
| Boxed mixes (cake, brownie, pancake) | 12 months |
| Cereal | 6–12 months |
| Peanut butter | 6–12 months |
| Shelf-stable juice, juice boxes | 6–12 months |
| Condiments, sauces (unopened) | 12–18 months |
| Snack foods, crackers, chips | 3–6 months (quality only) |
| Nutrition drinks (Ensure, Boost) | Use by date, do not extend |
| Baby food, infant formula | **NEVER past date** |
| Dairy, eggs, fresh meat, produce | Do not extend past date |

### Recall matching

- Match on **brand + product description + lot/date code**, not brand alone.
- Confidence tiers:
  - `CONFIRMED` — brand + product + lot code all match → block from shelf
  - `POSSIBLE` — brand + product match, lot code unreadable or not compared →
    REVIEW, surface the recall's lot codes for a human to check
  - `WEAK` — brand match only → informational flag, item proceeds normally with a
    note
- Only query **active** recalls (`status:"On-Going"`). Terminated recalls are noise.
- Never auto-discard on `POSSIBLE` or `WEAK`.
- The recall verdict reasons **only** over records actually retrieved from
  openFDA plus the scanned label. It must cite the recall number. It cannot
  invent a recall.

### Human control

- No item reaches the shelf without human clearance.
- `ClearItem` must **refuse** to clear an item carrying a `CONFIRMED` FlaggedBy
  edge. Enforce this in the walker, not in the UI — it must hold no matter what
  calls the endpoint.
- Low-confidence or unreadable extraction → REVIEW, never a guess onto the shelf.

### Privacy

- `Household` nodes hold **no** personally identifying information. No name, no
  address, no phone, no email.
- Distribution is tracked by an anonymous pickup code (4-digit, generated at
  pickup). A household that wants recall notifications supplies a contact method
  themselves and it is stored against the code, opt-in only.
- Do not add "helpful" identity fields. The privacy design is a feature we will
  demo, not an oversight to correct.

### Framing

- **Never** state that a food is safe. All output is "here is what the label
  shows, check the label to confirm."
- Allergen tags are always "the label lists" / "the label does not list," never
  "contains" / "free from."

---

## 5. Graph schema

```
root
 └─> Pantry
      ├─> Shelf ──Stocks──> Item ──Contains──> Allergen
      │                       │
      │                       └──FlaggedBy──> RecallRecord
      │
      ├─> Household ──Avoids──> Allergen
      │        │
      │        └──Received──> Item
      │
      └─> RecallFeed ──Lists──> RecallRecord
```

### Nodes

**`Pantry`** — `name`, `created_at`

**`Shelf`** — `name` (e.g. "canned goods", "review queue")

**`Item`**
- `brand: str`, `product: str`, `category: str`
- `ingredients_text: str`
- `date_value: str`, `date_type: str` (`best_by` | `use_by` | `sell_by` | `exp` | `unknown`)
- `lot_code: str`
- `packaging_note: str` (dents, bulging, seal state)
- `extraction_confidence: float`
- `legibility_note: str`
- `verdict: str` (`keep` | `review` | `discard`)
- `verdict_reason: str`
- `cleared: bool` (false until a human clears it)
- `scanned_at: str`

**`Allergen`** — `name: str`. Seed the FDA big 9: milk, eggs, fish, shellfish,
tree nuts, peanuts, wheat, soybeans, sesame. Plus dietary tags as Allergen-like
nodes: pork, beef, gelatin, alcohol (for religious restrictions), added sugar
(for diabetic filtering).

**`Household`** — `pickup_code: str`, `notify_contact: str` (opt-in, may be
empty), `preferred_language: str`. **No PII.**

**`RecallFeed`** — `last_synced: str`

**`RecallRecord`**
- `recall_number: str`, `recalling_firm: str`, `product_description: str`
- `reason: str`, `classification: str` (Class I/II/III)
- `code_info: str` (this is the lot code field — critical for §4 matching)
- `distribution_pattern: str`, `status: str`, `report_date: str`

### Edges

- `Stocks` — Shelf → Item
- `Contains` — Item → Allergen. Carries `evidence: str`, the ingredient words
  that justified the tag
- `FlaggedBy` — Item → RecallRecord. Carries `confidence: str`
  (`CONFIRMED`/`POSSIBLE`/`WEAK`) and `matched_fields: str`
- `Avoids` — Household → Allergen
- `Received` — Household → Item. Carries `pickup_code: str`, `timestamp: str`
- `Lists` — RecallFeed → RecallRecord

---

## 6. Walkers

Each becomes `POST /walker/<Name>` automatically.

### `IntakeScan` — spawns on `Shelf`

Input: base64 image.

1. Call `extract_label` (byLLM) → structured read
2. Create the `Item` node
3. Link `Contains` edges to `Allergen` nodes, with the justifying ingredient words
4. Call `shelf_life_verdict` (byLLM) with category, date type, days past code,
   packaging note
5. `visit` the `RecallFeed`, compare against `RecallRecord` nodes, create
   `FlaggedBy` edges at the appropriate confidence tier
6. Set `verdict` per §4. `cleared` stays false.
7. Report the item plus the reasoning trace

### `ClearItem` — spawns on `Item`

Human confirmation. Sets `cleared = true` and attaches to the appropriate shelf.

**Must refuse** if a `CONFIRMED` FlaggedBy edge exists. This check lives in the
walker.

### `MatchNeeds` — spawns on `Household`, `walker:pub`

1. Read the household's `Avoids` edges
2. `visit` the `Shelf`, traverse `Stocks` to reach `Item` nodes
3. Prune any Item with a `Contains` edge to an avoided `Allergen`
4. Prune uncleared items
5. Call `explain_for_client` (byLLM) for plain-language output in the
   household's preferred language
6. Report the filtered shelf

Accept free-text constraints too ("allergic to peanuts, vegetarian, diabetic")
and resolve them to Allergen nodes via byLLM.

### `RecallSweep` — spawns on `RecallFeed` — **this is the star**

1. Query openFDA for active recalls (§8), create/update `RecallRecord` nodes
2. For each new record, traverse the graph to find matching `Item` nodes and
   create `FlaggedBy` edges per the §4 confidence tiers
3. **For each matched Item, traverse backwards along `Received` edges to reach
   the `Household` nodes that took it home**
4. Report two lists:
   - Items still on the shelf to pull
   - Pickup codes to notify, with the recall reason in plain language

Step 3 is the whole point of the project. It is a backward traversal through a
distribution graph — natural in Jac, awkward in SQL, and absent from every
existing pantry system. Make it visible in the output.

---

## 7. byLLM functions

No prompt strings. Signature + types + `sem` annotations are the prompt.

### `extract_label(image) -> LabelRead`

Returns brand, product, category, ingredients text, date value, **date type**,
lot code, packaging note, confidence, legibility note.

Capturing `date_type` correctly is essential — the whole shelf-life fix depends
on distinguishing "best by" from "use by" from "exp."

### `shelf_life_verdict(category, date_type, days_past_code, packaging_note) -> ShelfLifeCall`

Returns `keep` | `review` | `discard` plus a reason in plain language.

The `sem` annotation carries the §4 shelf-life table and the rule that date
labels are quality indicators, not safety dates. This is where the fix to Flaw 1
actually lives — get this annotation right.

### `explain_for_client(item, constraints, language) -> str`

Plain language, any language, framed as "the label lists" not "contains."
Multilingual output is nearly free here and is a real accessibility win for
pantry clients — demo it.

### `resolve_constraints(free_text) -> list[str]`

Maps "allergic to peanuts, vegetarian, diabetic" onto Allergen node names.

---

## 8. openFDA integration

Endpoint: `https://api.fda.gov/food/enforcement.json`

No API key required for our volume (240 req/min, 1000/day per IP unauthenticated).

Query params: `search`, `limit`, `skip`.

Fields we use:

| Field | Use |
|---|---|
| `recall_number` | Identity, must be cited in verdicts |
| `recalling_firm` | Brand matching |
| `product_description` | Product matching |
| `code_info` | **Lot codes** — the key field for §4 confidence tiers |
| `reason_for_recall` | Shown to volunteers and households |
| `classification` | Class I/II/III severity |
| `status` | Filter to `"On-Going"` only |
| `distribution_pattern` | Geographic relevance |
| `report_date` | Recency |

Example: `search=status:"On-Going"&limit=100`

Timeout at 3 seconds with a cached snapshot fallback so a dead network never
blocks intake. Ship a snapshot JSON in the repo for demo reliability — **the
venue wifi will be bad, plan for it.**

---

## 9. Deployment

Decide the topology in the first 45 minutes. Do not debug deploys at 6 PM.

**Revised 12:40 PM once the toolchain was actually inspected.** The original plan
assumed `jac build --client web` and a separate Vercel frontend. Neither is needed:
a single `jac start` process serves the API *and* the client bundle.

- **One host: Railway, from the `Dockerfile`.** `jac start main.jac --port $PORT`
  serves `/walker/<Name>` and renders the `.cl.jac` client at `/`. Set
  `GEMINI_API_KEY` as a Railway environment variable.
- **Persistence is SQLite at `.jac/data/`, zero setup.** Keep `numReplicas: 1` —
  multi-replica plus SQLite corrupts the graph, and Mongo is not worth it today.
- **No Vercel.** The deliverable is a live URL that loads on a judge's phone; one
  Railway URL satisfies it with the fewest moving parts.
- The image is `node:22` + Python because the client bundle is built by vite. A
  plain Python buildpack has no node and the build fails there — that is the
  specific 6:45 PM failure this avoids.
- `jac start` exits when stdin closes, so the container command must end in
  `< /dev/null`. This is mandatory, not cosmetic.

**Deploy a hello-world through this chain before writing any features.**
More hackathon projects die to a 6:45 PM deploy failure than to bad ideas.

### Fallback, and its trigger

The `.cl.jac` frontend is confirmed working, so the original fallback is retired.
The remaining risk is the Railway deploy itself. If the image is not live **by
4:00 PM**, fall back to running `jac start` locally behind a tunnel
(ngrok/cloudflared) for the demo. Keep all logic in Jac walkers regardless — the
fallback surrenders the hosting, never the backend.

---

## 10. Build order

Roughly 5.5 hours of actual build time after workshops and meals. Scope is the
four walkers. Everything else is polish.

| Time | Milestone |
|---|---|
| 10:45–11:00 | Scaffold, README, first commit |
| 11:00–12:00 | *(Jac workshop — run the deploy spike in parallel)* |
| 12:00–12:30 | **Deploy pipeline green end to end** |
| 12:30–1:00 | Graph schema, seed Allergen nodes |
| 1:00–2:15 | `IntakeScan` with stubbed extraction, then real `extract_label` |
| 2:15–3:00 | `shelf_life_verdict` + `ClearItem` refusal gate |
| 3:00–3:30 | `MatchNeeds` |
| 3:30–4:30 | **`RecallSweep` including the backward traversal** |
| 4:30–5:30 | Frontend screens, demo seed data |
| **5:50** | 🚨 **PARTIAL DEVPOST SUBMISSION — non-negotiable** |
| 6:00–6:45 | Demo video, real-photo eval |
| 6:45–7:10 | README, final submission |

Keep the deploy green all day. If a change breaks it, fix it before moving on.

### The eval (do it, it is a differentiator)

Between 6:00 and 6:45, photograph 20–30 real food labels around the venue —
snacks, drinks, whatever is on the sponsor tables. Run them through `IntakeScan`.
Record extraction accuracy and how many routed to review.

A small **real** eval beats a large synthetic one. v1's benchmark was synthetic
and honestly labeled as such; being able to say "we tested on 24 real labels an
hour ago" is far more convincing to a judge.

---

## 11. Definition of done

The demo must show, live, on deployed infrastructure:

- [ ] Scan a physical item with a phone camera → verdict in under 10 seconds
- [ ] A past-date shelf-stable item routes to REVIEW with shelf-life guidance,
      and the UI states that v1 would have discarded it
- [ ] A brand-only recall match shows lot codes for comparison, does not discard
- [ ] `ClearItem` visibly refuses on a CONFIRMED recall flag
- [ ] Free-text client search returns a filtered shelf with plain-language reasons
- [ ] Client output renders in a second language
- [ ] **`RecallSweep` runs and names the pickup codes of households that received
      a newly recalled item**
- [ ] Railway URL loads on a judge's phone
- [ ] `README.md` has a "Where Jac runs" section pointing at specific files and
      line ranges

---

## 12. Demo script — 4 minutes

Demo & Story is 20% and the rubric says a working demo beats a deck.

- **0:00–0:30** — Hold up a physical can. "A volunteer has 400 of these and a line
  out the door. One is recalled." Introduce Maria (§2). One person, not a market.
- **0:30–1:30** — Scan it live. Show the verdict and the new node in the graph.
- **1:30–2:10** — Client side: "peanut allergy, diabetic." Walker traverses,
  shelf filters. Switch language.
- **2:10–3:10** — **The money shot.** Trigger an FDA recall. `RecallSweep` fires,
  pulls items off the shelf, then traverses backwards: "two households received
  this — pickup codes 4471 and 8830." Pause. "No existing pantry system can do
  that."
- **3:10–4:00** — Open the walker source. Point at `visit`, at `by llm()`, at the
  complete absence of database code. The rubric says *show* where Jac runs.

### Tracks to select on Devpost

Agentic AI (1st = $2,000 — the walkers are a legitimate agentic system),
Social Impact, Best JacHammer, Best Use of Jaclang. Not fintech, not defense.

---

## 13. Rubric we are scored against

| Criterion | Weight | What earns a 5 |
|---|---|---|
| **Use of Jac** | **40%** | Product depends on Jac, used with depth or originality: walkers, graph traversal, byLLM, agentic flows |
| Real-World Use Case | 20% | A problem worth solving and a convincing way to solve it. Name one person |
| Technical Execution | 20% | Ambitious scope cleanly pulled off in one day |
| Demo & Story | 20% | Complete, clear, demoed with real evidence |

Minimum 3 on Use of Jac to qualify for **any** prize. Highest score there also
wins Best JacHammer.

Judged against one day of building, not a funded roadmap. Scored on what is
shown, not what is promised.

---

## 14. Commit style

Commit often — after each working unit, not in batches. Target 15–25 commits
across the day.

- **No conventional commits.** Never write `feat:`, `fix:`, `chore:`, `docs:`,
  `refactor:`.
- Lowercase, no trailing period.
- Mostly one line. Add a body only for something genuinely non-obvious, which is
  rare.
- **Vary length and register.** Some 2–3 words (`wip`, `typo`, `readme`). Some a
  normal sentence. Occasionally one that sounds like relief or annoyance.
- Describe what changed, not what category it belongs to.
- No emoji. No `Co-Authored-By` trailer. No "Generated with" line.
- Leave the messy commits in. Small fixes right after a big commit are normal.
- Do not squash, rebase, or amend unless asked.

Also set in `.claude/settings.json`:

```json
{ "includeCoAuthoredBy": false }
```

Target texture:

```
set up jac project, hello world running
got the deploy working on railway finally
pantry graph — shelf, item, household nodes
intake walker skeleton, extraction still stubbed
hook up byllm for label reading
label extraction works on real cans now
wip shelf life
replace the expiry check with actual shelf-life reasoning
past-date shelf stable no longer gets thrown out
can't clear an item that has an active recall flag
match needs walker, traverses the avoid edges
client search returns a filtered shelf
recall sweep pulls from openfda
backward traversal to households works!!
lot code matching so we stop flagging whole brands
seed data for the demo
intake screen
shelf view + pickup codes
fix scanning twice making duplicate nodes
typo
readme
architecture notes + where jac lives
```

---

## 15. Working style

- Deploy stays green all day.
- Do not refactor working code unless asked.
- When a unit is done: commit it, then say what to test manually.
- If you are stuck on Jac syntax for more than 10 minutes, say so — there are Jac
  mentors on site and asking a human is faster than guessing.
- Do not add features not in this spec. Scope is the enemy today.
