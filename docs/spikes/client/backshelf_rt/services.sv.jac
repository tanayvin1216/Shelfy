"""Backshelf server layer."""
import base64;

node Item {
    has label: str,
        lot: str,
        recalled: bool = False;
}

walker:pub AddItem {
    has label: str,
        lot: str,
        reports: list[Item] = [];

    can go with Root entry {
        report (here ++> Item(label=self.label, lot=self.lot))[0];
    }
}

walker:pub ListItems {
    has reports: list[Item] = [];
    can go with Root entry { visit [-->]; }
    can grab with Item entry { report here; }
}

walker:pub SweepRecall {
    has lot: str,
        reports: list[Item] = [];
    can go with Root entry { visit [-->]; }
    can mark with Item entry {
        if here.lot == self.lot { here.recalled = True; report here; }
    }
}

walker:pub ScanLabel {
    """Receive a camera frame as a base64 data URL over plain JSON."""
    has filename: str,
        data_url: str,
        reports: list[dict] = [];

    can go with Root entry {
        b64 = self.data_url.split(",")[-1];
        raw = base64.b64decode(b64);
        report {"filename": self.filename, "bytes": len(raw)};
    }
}
