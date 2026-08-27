# Wallpapers

This directory ships empty on purpose — put your own images here.

The images used on the machine this came from are not included: most of them
were downloaded from [wallhaven.cc](https://wallhaven.cc) and are not ours to
redistribute, and 85 MB of JPEGs in a config repository serves nobody.

## Where they go

`install.sh` links this directory to `~/.config/hypr/wallpapers`, which is where
`wallpaper.sh` looks. Drop files in either place; they are the same directory.

```bash
cp ~/Pictures/some-wallpaper.png ~/.config/hypr/wallpapers/
```

- Formats: `.jpg`, `.jpeg`, `.png`, `.webp`
- Any resolution works. 3840x2160 is a good default; the login-screen copy is
  downscaled automatically, so a 4K original costs nothing there.
- The order in the `SUPER+W` cycle is the sorted filename order, so a `01-`,
  `02-` prefix is enough to arrange them.

## Getting a set to start with

Four monochrome 4K wallpapers are generated procedurally by
[hypr-lock-theme](https://github.com/Whyslab/hypr-lock-theme) — no download, no
licensing question:

```bash
git clone https://github.com/Whyslab/hypr-lock-theme.git
cd hypr-lock-theme
python3 scripts/generate_wallpapers.py --out ~/.config/hypr/wallpapers
```

Or list wallhaven ids in `wallpapers.list` and fetch them:

```bash
cp wallpapers.list.example wallpapers.list
$EDITOR wallpapers.list
./fetch-wallhaven.sh
```

## Three targets, one command

`wallpaper.sh` drives three independent backgrounds, which is why the picker
asks which one you mean:

| Target | Who reads it |
|---|---|
| desktop | the `awww` wallpaper daemon |
| lock screen | `hyprlock`, through a symlink |
| login screen | SDDM, from `/var/lib/sddm-wallpaper/current.jpg` |
