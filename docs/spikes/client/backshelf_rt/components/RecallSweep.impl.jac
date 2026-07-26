impl RecallSweep.sweep(e: FormEvent) -> None {
    e.preventDefault();
    if not lot.strip() { return; }
    result = root spawn SweepRecall(lot=lot);
    hits = result.reports;
    swept = True;
}
