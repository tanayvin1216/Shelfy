cl import from "@jac/runtime" { Outlet, Link, useLocation }

cl {
    def:pub layout() -> JsxElement {
        loc = useLocation();
        return <div>
            <nav style={{"display": "flex", "gap": "1rem", "padding": "1rem"}}>
                <Link to="/">Intake</Link>
                <Link to="/shelf">Shelf</Link>
                <Link to="/recall">Recall sweep</Link>
            </nav>
            <p>path: {loc["pathname"]}</p>
            <main><Outlet /></main>
        </div>;
    }
}
