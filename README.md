# macwm

A dwindle tiling window manager for macOS. New windows split the focused pane. Wide panes split left and right. Tall panes split top and bottom. Each display keeps its own tree for the macOS Space you are already on.

Mission Control, trackpad gestures, and fullscreen Spaces stay Apple's. macwm never creates or switches a Space, and it does not need SIP turned off.

A move eases into place with the display refresh. Resize keys track the keyboard immediately. With Reduce Motion on, every change snaps.

## Install

You need macOS 14 or later, and Xcode or a Swift toolchain.

```sh
git clone https://github.com/benbrackenbury/macwm.git
cd macwm
make run
```

`make run` builds a release app, signs it ad-hoc, and opens `macwm.app`. The menu bar icon is a split rectangle.

On first launch, macOS asks for Accessibility access. Allow it. macwm cannot move windows without that permission. The same permission is what lets the globe key act as a shortcut modifier.

Then, in System Settings:

1. Keyboard, then Press the globe key to, then Do Nothing.
2. Turn Stage Manager off. It fights any tiling window manager.

A rebuild changes the ad-hoc signature, so macOS may forget the Accessibility grant. Toggle macwm off and on in Privacy & Security, Accessibility.

The first launch writes `~/.config/macwm/config`. Saving that file reloads it. The menu can open the file, reload it, turn tiling off, or quit. Quitting leaves windows where they are.

## Shortcuts

Every shortcut includes the main modifier. The default is the globe key, which is the fn key.

| Shortcut | Action |
| --- | --- |
| Globe-H / J / K / L | Focus left / down / up / right |
| Globe-Shift-H / J / K / L | Swap the focused window with that neighbor |
| Globe-Control-H / J / K / L | Grow the focused pane that way |
| Globe-T | Float or tile the focused window |
| Globe-W | Close the window, same as the red button |
| Globe-Shift-R | Reload the config |

Globe plus an arrow key is Home, End, Page Up, or Page Down, so the defaults use hjkl. Arrow keys are fine when the modifier is Option. The commented example at the bottom of the config shows that.

Dragging a tiled window snaps it back on mouse up. Dragging it onto another display joins that display's tree.

## Config

`~/.config/macwm/config`

```
modifier = globe
gaps_inner = 8
gaps_outer = 8
split_ratio = 0.5

float = com.apple.SystemSettings
float = com.apple.calculator

bind = h, focus left
bind = shift+h, move left
bind = ctrl+l, resize right
bind = t, toggle float
```

`modifier` is `globe`, `option`, `control`, `command`, or a combination such as `ctrl+option`. It is held for every bind.

`gaps_outer` is the space inside the menu bar and Dock. `gaps_inner` is the space between panes. `split_ratio` is the share given to the existing pane when a new window splits it. `0.5` is half.

`float` is a bundle id that should stay where the app put it. Dialogs, sheets, and panels are already ignored. One `float` line replaces the whole default list. One `bind` line replaces the whole default shortcut list. Lines starting with `#` are comments.

If the globe key does nothing, the keyboard is not sending fn. Set `modifier = option`.

Set `MACWM_DEBUG=1` in the environment before launch to print each layout pass.

## Develop

```sh
make test
make app
```

`make test` runs the layout and config tests. `make app` builds `macwm.app` and leaves it unopened.
