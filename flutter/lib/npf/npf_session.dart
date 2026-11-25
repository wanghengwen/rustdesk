/// npf's Android app (oudesk_module): back on a session page leaves the
/// session running, out of sight (the app's pages list keeps it as a card);
/// null elsewhere: back closes it, as RustDesk does.
void Function()? npfLeaveSession;

/// npf's iOS app (oudesk_module): RustDesk's own files (its config, its keys)
/// in the app's support directory, out of Documents, which the Files app
/// shows as the app's (npf's downloads there); the file transfer's side on
/// the phone in Documents/ouLink, so its files are seen in the Files app.
/// false elsewhere: Documents, as RustDesk has it.
bool npfIosDirs = false;
