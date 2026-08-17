# Hello Extension

This unpacked Manifest V3 example verifies content-script matching and injection without changing the host page layout. It shows a small, non-interactive badge for three seconds, writes the current URL through `chrome.storage.local` when available, sends a best-effort runtime message, and exposes a local action popup that reads the saved URL.

Create the importable package from the repository root:

```powershell
Compress-Archive -Path .\Examples\HelloExtension\manifest.json, .\Examples\HelloExtension\content.js, .\Examples\HelloExtension\content.css, .\Examples\HelloExtension\popup.html, .\Examples\HelloExtension\popup.css, .\Examples\HelloExtension\popup.js -DestinationPath .\HelloExtension.zip -Force
```

`manifest.json` must be at the root of the ZIP. In ExtensionBrowser, open **Menu > Extensions > Import Extension**, choose `HelloExtension.zip`, review the requested permissions, and install it. Open any HTTP or HTTPS page to see the badge, then tap the puzzle-piece action button to open the popup.
