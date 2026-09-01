# Omarchy menu + Menu Look

A clone of the built-in [Omarchy](https://omarchy.org/) command menu
(`omarchy.menu`) with one addition: a **Menu Look** row under Style that lets
you scale this menu's size, round its corners, set its border width, and
adjust its transparency — live, as you drag — without touching the theme or
any other part of the shell.

## Why a clone

The menu's font size, corner radius and border width all come from the
shell's *global* style tokens (`Style.cornerRadius`, `Style.font.*`, …), the
same ones the bar and every panel use. There's no hook to restyle just the
menu from outside its own QML, so the only way to add menu-only controls is
to own the menu itself — the same approach `omarchy plugin clone omarchy.menu`
gives you.

This means it's a fork of `Menu.qml`/`MenuModel.js`. The diff against the
built-in menu is intentionally small (see below) to keep re-merging upstream
changes after an Omarchy update easy.

## Use

Open the menu as usual (`SUPER + SPACE`) → **Style → Menu Look**. Drag any
slider and the card restyles immediately:

| Knob | Range | Default |
|---|---|---|
| Size | 0.8×–1.5× | 1.0× |
| Corner roundness | 0–24 px | theme's `decoration:rounding` |
| Border width | 0–6 px | theme default |
| Transparency | 0–90% | 0% (opaque) |

**Reset to theme defaults** clears all four back to "inherit from the shell
theme" — an unconfigured install renders pixel-identical to the stock menu.

Settings are stored in `~/.local/state/omarchy/deunnis.menu/style.json` and
apply only to this menu; the bar, panels, and every other surface are
untouched.

## What's changed vs. the built-in menu

- `Menu.qml`: `cornerRadius` and the card's border width read from the new
  config (falling back to the same `Style.*` expressions as before); the card
  gets a `scale` + background-alpha override; a "Menu Look" row is injected
  under Style and intercepted in `activateIndex()` to open `MenuLookEditor`
  in place of the row list.
- `MenuLookEditor.qml`: new file, the sliders view.
- `MenuModel.js`, `BarWidget.qml`: unchanged from the built-in menu.

## Development

```bash
omarchy plugin validate ~/.config/omarchy/plugins/deunnis.menu
omarchy restart shell   # plugin QML is cached by URL — logic changes
                         # (not just property bindings) need a real restart,
                         # not just a save-triggered hot reload
```

## Remove

Removing this plugin (or disabling it) switches the bar's menu button and the
`omarchy.menu` IPC target back to the built-in menu automatically — that's
what `clonedFrom` is for.

```bash
omarchy plugin remove deunnis.menu
```

`~/.local/state/omarchy/deunnis.menu/` (the style.json above) is left behind;
delete it if you want a clean slate.
