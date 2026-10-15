# DOM launcher comparison

Three actual DOM launchers: a sidebar entry, a header menu, and a floating button.
They activate an existing official **History sync** button to open the same pane.
There is no second copy engine, account selector, or automatic-sync permission.
If the official launcher is absent, they disable themselves instead of submitting
a command or editing the prompt.

The sidebar and header use semantic DOM anchors. When no matching anchor exists,
they use a left-edge or top-edge fallback. The menu reports which happened.
React navigation is handled by a MutationObserver; disposal removes all injected
nodes and observers. Placement preferences contain only a display choice.

## Try it in the Microsoft Store build

The reference `claude-ui-mod` patcher targets a different installation layout.
This experiment uses Electron's DevTools endpoint to load `renderer.js` into the
Claude page without editing installed archives, executables, or their integrity
metadata. It is a temporary comparison, not a permanent installer.

The endpoint lets other local processes inspect the Desktop page while enabled.
It binds to loopback on a dynamically chosen port. The startup script verifies
that the listener belongs to the selected Desktop executable, and the injector
refuses other hosts, ports, protocols, or non-Claude page targets.

1. Save or pause active work and fully exit Claude Desktop from its tray icon.
2. In PowerShell, run:

   ```powershell
   Set-Location C:\path\to\ClaudeSync
   .\experiments\dom-launchers\Start-DesktopDom.ps1
   ```

3. Open a local Code session with the official History sync launcher enabled.
   Compare **Sidebar**, **Menu**, and **Floating**. All open the existing pane.
4. Use the DOM menu to keep one placement. Alt-click Sidebar to reopen the menu
   when only that placement is enabled.
5. Ctrl+C in PowerShell removes the injected controls. Fully exit Desktop and
   restart it normally to close the debugging endpoint.

Requires Node 22+ for the loader; no npm packages are needed to run it. If this
Desktop build refuses the debugging flag, the script reports that and does not
patch the installation. The injector handles new page targets and page reloads.

**Verification:** eleven DOM/loader/preview fixture tests pass. Live injection into the
Store app still requires the restart comparison; fixture tests do not prove
the actual app's DOM anchors or startup flag are accepted.

## Use with an existing claude-ui-mod runtime

`renderer.js` also follows its renderer contract. Copy it into a new
`src/plugins/history-sync-launchers/renderer.js` inside an already installed
runtime. It registers cleanup through `ctx.onDispose`; it does not require a
main-process plugin or invoke the runtime's filesystem or private IPC APIs.
Do not run the reference's regular-install patcher against a Store installation.

## Preview and tests

The [interactive comparison](../../docs/history-sync-preview.html) embeds the
same native and DOM code using fixture accounts. Styling and anchors approximate
Desktop; this preview performs no real copies.

```powershell
Set-Location .\experiments\dom-launchers
npm ci --ignore-scripts
npm test
```

The fixture tests use jsdom 30.1.1 and require Node 22.22.2+, 24.15+, or 26+.
They cover native-button delegation, disabled fallback, React replacement,
sidebar reattachment, remembered display choices, removal, and hot-reload cleanup.
