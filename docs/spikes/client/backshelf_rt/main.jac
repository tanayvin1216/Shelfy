"""Backshelf entry - file-based routing via pages/."""
import from services { Item, AddItem, ListItems, SweepRecall, ScanLabel }

cl {
    def:pub app(children: any = None) -> JsxElement {
        return <div style={{"fontFamily": "system-ui, sans-serif"}}>{children}</div>;
    }
}
