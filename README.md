# Backshelf

A food pantry intake and recall-propagation system, built in Jac.

Roughly 60,000 food pantries in the US run on volunteers and clipboards. Donations
arrive unsorted, unbarcoded and undated. A grocery shopper gets recall alerts and
clear labels for free; a family picking up food from a pantry shelf gets neither.

**The gap this targets:** a recall announced on Tuesday affects the can that went out
the door on Saturday. Food banks brief volunteers and post notices, which protects
food still in the building. Nobody can tell a *specific household* that the jar in
their cupboard is now recalled — because nobody keeps a graph connecting recalls to
items to the households that received them.

Backshelf keeps that graph.

## Where Jac runs

_(filled in as the walkers land)_

## Rebuild note

This is a rebuild of my own earlier prototype, Shelfy (React Native + Gemini +
SQLite), which scanned donations at intake for recalls, expiry and allergens. v1
shipped and then showed three design flaws — past-date items were routed to discard,
recalls were matched on brand alone, and checking only happened at intake. v2 exists
to fix all three. See `CLAUDE.md` §3.

## Stack

- jaclang 0.16.7 — nodes, edges, walkers, `by llm()`, root-reachability persistence
- byllm 0.6.19 — label extraction, shelf-life reasoning, client explanations
- openFDA food enforcement API — active recall records

No database layer. No hand-written REST routes. No prompt strings.
