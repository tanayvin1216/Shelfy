"""Backshelf - entry point.

    jac start main.jac

One process serves the whole product: every walker below is exposed as
`POST /walker/<Name>` automatically, and the `cl { }` block at the bottom
renders the Jac client at `/`. There are no hand-written routes, no database
layer and no separate frontend server anywhere in this repo.

The API surface, in the order the demo uses it:

    POST /walker/SeedPantry    graph.sv.jac        idempotent skeleton
    POST /walker/SeedDemo      demo.sv.jac         Maria's distribution history
    POST /walker/IntakeScan    intake.sv.jac       scan one donation
    POST /walker/ClearItem     intake.sv.jac       the human clearance gate
    POST /walker/MatchNeeds    client_search.sv.jac client-side shelf search
    POST /walker/RecallSweep   sweep.sv.jac        the retroactive sweep

Everything else in those modules is underscore-prefixed and stays private.

Importing the walkers here is what registers them: an endpoint serves if the
entry module imports it or a `.cl.jac` module references it through
`sv import`. The types come along so the reports hydrate on both sides of the
wire instead of arriving as untyped dicts.
"""

import from graph {
    SeedPantry, SeedReport,
    Pantry, Shelf, Item, Allergen, Household, RecallFeed, RecallRecord,
    ItemView, AllergenTagView, RecallFlagView
}
import from demo { SeedDemo, DemoReport, DemoHandout }
import from intake {
    IntakeScan, ClearItem,
    IntakeReport, ClearReport, TraceStep, AllergenHit, RecallMatch
}
import from client_search { MatchNeeds, MatchReport, ShelfMatch, WithheldItem }
import from sweep { RecallSweep, SweepReport, FlaggedItem, NotifyHousehold, SweepHop }

cl {
    import from .frontend { app as BackshelfApp }

    def:pub app -> JsxElement {
        return <BackshelfApp/>;
    }
}
