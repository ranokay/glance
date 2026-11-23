ObjC.import("Foundation");
ObjC.import("AppKit");

function run(arguments) {
    if (arguments.length !== 1) throw new Error("Expected one named pasteboard");
    var pasteboard = $.NSPasteboard.pasteboardWithName(arguments[0]);
    var request = ObjC.unwrap(pasteboard.stringForType("com.chamburr.Glance.open-with-request"));
    if (!request) throw new Error("The named request pasteboard was empty");
    var components = $.NSURLComponents.componentsWithString(request);
    var payload = components.queryItems.objectAtIndex(0).value;
    var jsonData = $.NSData.alloc.initWithBase64EncodedStringOptions(payload, 0);
    var jsonError = Ref();
    var json = $.NSJSONSerialization.JSONObjectWithDataOptionsError(jsonData, 0, jsonError);
    if (!ObjC.unwrap(json)) throw new Error("Invalid request JSON");
    var bookmark = $.NSData.alloc.initWithBase64EncodedStringOptions(json.objectForKey("fileBookmark"), 0);
    var stale = Ref();
    var error = Ref();
    var url = $.NSURL.URLByResolvingBookmarkDataOptionsRelativeToURLBookmarkDataIsStaleError(
        bookmark, $.NSURLBookmarkResolutionWithoutUI, $(), stale, error
    );
    if (!ObjC.unwrap(url)) throw new Error("Bookmark resolution failed");
    var contents = $.NSData.dataWithContentsOfURL(url);
    if (!ObjC.unwrap(contents)) throw new Error("The resolved file was unreadable");
    return JSON.stringify({
        processID: Number($.NSProcessInfo.processInfo.processIdentifier),
        path: ObjC.unwrap(url.path),
        stale: Boolean(stale[0]),
        contents: ObjC.unwrap(contents.base64EncodedStringWithOptions(0))
    });
}
