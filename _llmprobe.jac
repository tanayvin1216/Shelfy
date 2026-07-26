import from llm { extract_label, shelf_life_verdict, resolve_constraints, explain_for_client, image_from_base64, DateType, ShelfVerdict, LabelRead, ShelfLifeCall, ItemForClient }

walker:pub ProbeVerdict {
    has category: str = "canned_low_acid";
    has days_past_code: int = 847;
    can go with `root entry {
        c = shelf_life_verdict(self.category, DateType.BEST_BY, self.days_past_code, "no visible damage");
        report {"verdict": str(c.verdict), "reason": c.reason, "window": c.typical_window_past_code};
    }
}
