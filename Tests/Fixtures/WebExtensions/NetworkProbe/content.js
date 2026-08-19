// Scope probe. Not a measurement of blocking — a measurement of whether this extension has
// any authority over the loopback page at all.
//
// If <all_urls> did not cover an IP-literal host, the extension would simply have no say over
// http://127.0.0.1:<port>/ and the declarativeNetRequest result would mean nothing. This marks
// the DOM so the Swift side can read the answer directly, without depending on runtime messaging
// (which is a separate unproven surface, and sendNativeMessage is background-only anyway).
document.documentElement.setAttribute("data-kiwix-content-script", "1");
