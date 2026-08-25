# VirtualBar

**English** · [简体中文](README.zh-CN.md)

VirtualBar is a proof of concept for a virtual menu bar on macOS 14 and later.

## Install

```bash
curl -fsSL https://github.com/MuqiuPeng/VirtualBar/releases/latest/download/VirtualBar.zip -o /tmp/VirtualBar.zip \
  && ditto -x -k /tmp/VirtualBar.zip /Applications \
  && xattr -dr com.apple.quarantine /Applications/VirtualBar.app \
  && rm /tmp/VirtualBar.zip \
  && open /Applications/VirtualBar.app
```

Three things worth knowing:

- Extract with `ditto`, not `unzip`. An `.app` is a signed bundle, and `unzip` can damage the resource structure inside it.
- `xattr -dr com.apple.quarantine` is required. VirtualBar is ad-hoc signed and not notarised by Apple, so Gatekeeper refuses to launch it while the quarantine attribute is set. This affects only VirtualBar itself; it does not change your system's Gatekeeper settings.
- First launch asks for two permissions: Accessibility (to activate the original status item) and Screen Recording (to capture the real icons). Without Screen Recording it falls back to the owning application's icon.

Uninstall:

```bash
rm -rf /Applications/VirtualBar.app
```

## How it works

VirtualBar keeps just one toggle button and one hidden spacer in the system menu bar. Once the spacer has folded the third-party menu bar icons away, clicking the VirtualBar button brings up a compact virtual bar. What that bar shows is live icon imagery captured through ScreenCaptureKit; clicking an icon performs an `AXPress` on the original third-party status item through Accessibility.

The virtual bar no longer positions icons at their original screen coordinates — it uses a compact single-row layout. Content beyond 520pt scrolls horizontally, so an icon sitting behind the notch or off-screen can never stretch the bar past the edge of the display.

The current UI uses three plain filled dots as the VirtualBar icon, with no surrounding ring. Virtual bar icons are 34pt with a 40pt hit area, the panel is 48pt tall and at most 520pt wide. Every button has hover and pressed accent backgrounds; the panel is a titleless, borderless, non-resizable window with 12pt continuous corners, zero border width and no system window shadow, and focus rings are disabled on both the content and the buttons.

The virtual bar is anchored to the VirtualBar menu bar button, offset 28pt to the right of it. Right-clicking the VirtualBar icon and choosing `Settings…` opens the settings window, where you can tick which icons belong in the virtual bar, reorder them by dragging, refresh the current third-party icons, and restore the system's natural order.

Visibility and ordering are persisted against a stable item identity rather than list indices. New third-party items are inserted in the system's natural order; an item that disappears temporarily does not lose its stored preference, and its visibility and position are restored when it comes back.

Clicking any virtual icon:

1. Closes the virtual bar.
2. Drops the spacer to zero so the original status item returns to its natural position.
3. Re-resolves that item's live window identity and frame.
4. Performs `AXPress` on the original item.
5. Watches for menu or popover windows appearing in the target process.
6. Only re-folds the third-party icons once the target UI has actually closed.

This is what avoids the earlier problem of a menu opening and immediately losing focus because the spacer was restored straight away. There is no short fixed timeout once the UI has been detected — the menu can stay open indefinitely, and the layout is only reclaimed after its window disappears and stays gone for a full second. If an application exposes no observable window, VirtualBar holds the expanded state for at least 20 seconds.

The target UI losing focus also triggers reclamation. VirtualBar watches for global mouse clicks outside the target's popover and for frontmost-application changes; after such an interaction it waits 250ms before restoring the spacer. Clicking *inside* the target menu or popover does not trigger it, because the click location is hit-tested against the live frames of the target process's new windows.

Click outcomes distinguish popovers from ordinary window navigation. Menu and popover windows follow the full lifecycle above. If the target application comes to the front, or the new window is an ordinary application window, and no popover window has appeared within 600ms, the navigation is treated as complete and the spacer is restored immediately — so an entry point that opens a main window, as Notion's does, stops occupying the expanded menu bar space.

`AXPress` returning `AXError.cannotComplete` is no longer treated as an immediate failure. Once a status bar menu enters its synchronous tracking loop it often cannot answer AX requests in time, even though the action was delivered and the menu did appear; VirtualBar proceeds into window lifecycle monitoring rather than wrongly restoring the spacer.

The old paging masks and menu bar curtain have been removed from the running code, so the virtual bar never paints a dark overlay onto the menu bar.

## Capability boundaries

- Ordinary third-party status items: capture and Accessibility activation both supported.
- System Control Center items: not included in the virtual bar.
- Live Activities: not included in the virtual bar.
- Writing cross-process coordinates onto an individual third-party status item: supported by neither the public API nor Accessibility.
- Menu anchoring is still determined by each third-party application's own real status item. VirtualBar does not fabricate menus.

## Permissions

- Accessibility, to activate the original third-party status item.
- Screen Recording, to capture the real icons. Without it, the owning application's icon is used as a fallback.

If Accessibility is not yet in effect, VirtualBar leaves the real icons expanded rather than hiding them first.

## Build and run

```bash
Scripts/build-app.sh debug
open .build/debug/VirtualBar.app
```

Runtime logs go to `/tmp/virtualbar.log`, covering whether the virtual bar has closed, whether the target UI was detected, when it actually closed, and when the spacer re-folded.
