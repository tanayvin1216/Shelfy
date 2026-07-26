impl IntakeForm.submit(e: FormEvent) -> None {
    e.preventDefault();
    if not label.strip() or not lot.strip() { return; }
    result = root spawn AddItem(label=label, lot=lot);
    added = added + [result.reports[0]];
    label = "";
    lot = "";
}

impl IntakeForm.on_photo(e: ChangeEvent) -> None {
    files: any = e.target.files;
    if not files or files.length == 0 { return; }
    f: any = files[0];

    # Read the camera frame as a base64 data URL (FileReader is promise-free,
    # so wrap it) -- `new()` is the Jac spelling for a JS constructor.
    reader: any = new(FileReader);  # jac:ignore[E1053]
    data_url: any = await new(Promise, lambda(resolve: any, reject: any) {  # jac:ignore[E1053,E1041]
        reader.onload = lambda(ev: any) { resolve.call(None, reader.result); };
        reader.onerror = lambda(ev: any) { reject.call(None, "read failed"); };
        reader.readAsDataURL(f);
    });

    preview = str(data_url);
    result = root spawn ScanLabel(filename=str(f.name), data_url=str(data_url));
    if result.reports and len(result.reports) > 0 {
        r: any = result.reports[0];
        scan_note = str(r["filename"]) + " -> " + str(r["bytes"]) + " bytes";
    }
}
