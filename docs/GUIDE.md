# Using tileit

TileIT is a quality of life tool for game artists and any person who wants to convert any texture into a seamless tiling texture. There will be some textures where additional handiwork will be required. In the current version you will have to check using your own eyes. No knowledge of the underlying technology is required, the only pre-requisite is that you have some experience and know what you're looking at (so that you know which settings to change). 

This guide is split into four parts using examples from [Unsplash](https://unsplash.com). Any texture will do, but your mileage will vary. 

1. [Your first tile](#1-your-first-tile): one run, start to finish.
2. [What the tool is doing](#2-what-the-tool-is-doing): the three ideas
   that explain every control.
3. [Recipes](#3-recipes): what to do for bricks, stone, sand, wood and full
   material sets.
4. [When it goes wrong](#4-when-it-goes-wrong): symptoms, causes and fixes,
   plus a reference of every control at the end.

---

## 1. Your first tile

### Open a texture

Start `tileit.exe`. A graphical user interface will pop up, as will a command line. The command line only outputs current debug output. You'll see two large panes: the left one is the input, the
right one shows the result repeated 3 × 3. If you prefer the Input pane on the right and the result on the left, activate the "Swap Sides" option. 
![[TileIT_Opened.png]]
Above: The user interface of TileIT. 

Drag a PNG or JPG from Explorer onto the window, or click **Open…**.
While the tool is made for the typical 2K or 4K textures, big photos are fine as well. The input appears on the left, if you wish the input to be on the right instead activate the option "Swap sides". The line at the bottom of the window shows its size and a **seam score**. More on that in a
moment.
![[Pasted image 20261127205609.png]]
### Press Tile it

Click **Tile it** or press **Space**. A progress bar appears on the right while
it works. Most textures take between one and five seconds depending on your hardware. 

When it's done, the right pane shows nine copies of the result laid next to
each other (if you change the setting "Preview" from 3x3 it will change accordingly, up to 25 tiles). . **Look at the lines where the copies meet.** If you can't find them, you're done.

### Save

Press **Ctrl+S** or click **Save**. The result is written next to your original
as `name_tiled.png`. **Save as…** lets you pick a different place instead.

The output keeps the format of the input: a greyscale map stays greyscale, and a
16-bit height map stays 16-bit.

> **Tip:** Drag the **Preview** slider up to 5 × 5 or 6 × 6 before you judge a
> result. Repetition that hides at 3 × 3 often jumps out at a larger count,
> because your eye starts to find the pattern rather than the seam.

### Reading the status line

After each run, the bottom line tells you what happened. For example:

```
Synth 1.8s  1 map(s)  repeat 766x821, quilted, cropped 2048x2048 -> 1532x1643, resized to 2048x2048  seam 2.49 -> 0.38
```

Read it left to right:

| Part                     | Meaning                                                                                                  |
| ------------------------ | -------------------------------------------------------------------------------------------------------- |
| `Synth 1.5s`             | Which mode ran, and how long it took                                                                     |
| `repeat 766x821`         | The texture repeats every 766 px across and 821 px down (bricks, tiles…)                                 |
| `quilted`                | The seams were joined using real pixels from the photo (the best case)                                   |
| `cropped … -> 1532x1643` | The part of the photo that holds whole repeats; why is explained in [2.2](#22-regular-textures-need-whole-repeats) |
| `resized to 2048x2048`   | The finished tile was scaled back to the size you started with (see **Output**)                          |
| `seam 2.49 -> 0.37`      | How visible the edge was before and after                                                                |

The **seam score** compares the jump in colour across the tile's edge with the
jump between ordinary neighbouring pixels. A raw photo usually scores
somewhere between 2 and 20. Anything around 1 or lower means the edge is no
more noticeable than the rest of the texture. The score only measures the edge,
though; it can't see repetition. Your eyes are still the final judge.

---

## 2. What the tool is doing

Every control in tileit exists because of one of three problems. Knowing them makes the controls easier to understand. 
### 2.1 Edges don't match

Put a photo next to a copy of itself and the right edge of one meets the left
edge of the other. Those two edges were never next to each other in real life,
so there's a visible line.

For textures without a pattern (sand, gravel, grass, rough plaster) the tool
fixes this in two ways:

- **Quick** spreads the mismatch smoothly across the whole image. It's fast and
  works well when the texture is fine-grained and busy.
- **Synth** goes further. It rebuilds a strip along each seam out of small
  pieces copied from elsewhere in the photo, so real texture runs across the
  join. The **Band** slider sets how wide that strip is.

Synth is the default. Use Quick when you want an instant result or Synth's fill
looks off.

### 2.2 Regular textures need whole repeats

Bricks, tiles, planks and paving have a **repeat**: the pattern comes back
after a fixed distance. A brick wall might repeat every two bricks across and
every four courses down.

A tile only joins cleanly if it contains a whole number of repeats. If it
stops halfway through a brick, the next copy starts with a whole brick, and you
get a half-brick sitting next to a full one. No blending can hide that.

So when **Fit to repeat** is on (the default), tileit measures the repeat and
trims the tile to fit it. On a 2048 × 2048 photo of bricks that leaves 1532 × 1643
pixels: exactly two repeats each way.

The finished tile is then scaled back to the size you started with, so you
still get a 2048 × 2048 texture. That's the **Output** setting, **Input** by
default. The scaling wraps around the edges, so it doesn't bring a seam back.
It does mean the bricks end up a little wider or taller than in the photo when
the fitted tile wasn't square (about 7% here). Choose **Output: Fitted** to keep
the fitted pixels exactly as they are, or **1K / 2K / 4K** for a standard size.

With a known repeat, the tool can also do the cleanest possible seam. The
photo itself shows what comes after the tile's edge: the same wall, one tile
further along. tileit finds the line where the tile and that continuation
match best, and switches over there. Every pixel in the result is a real
pixel from your photo. That's what **quilted** in the status line means.

If you'd rather keep the full width of your selection, switch **Crop** to
**Stretch**. The image is then scaled slightly (by at most 15%) instead of
trimmed, so it fits a whole number of repeats.

### 2.3 Photos aren't perfectly even

Real photos have flaws that only show once the texture repeats:

- **Tilt.** A wall shot slightly rotated has no clean horizontal repeat.
  **Straighten** (on by default) measures the tilt and rotates it out. It acts
  on tilts between 0.3° and 15° and ignores textures that have no straight lines
  to measure.
- **Edges of the frame.** Lenses distort and darken towards the corners.
  The **Trusted centre** (65% by default) is the part of the photo tileit
  measures and copies from. You'll see it as a thin outline on the input.
- **Lighting.** If one side of the photo is brighter, that gradient repeats
  as stripes. **Flatten** removes it.
- **Patchiness.** A washed-out or extra-dark area repeats as a blotch.
  **Even contrast** evens out local contrast across the texture. **Scale** sets
  how large an area Flatten and Even contrast look at.

---

## 3. Recipes

### Bricks, tiles, paving, planks

The defaults are tuned for this. Open, press Space, check the result.

1. Look at the status line. It should say `repeat …` and `quilted`.
2. If it says `no regular repeat`, the pattern wasn't clear enough. Try a
   larger selection, or make sure **Straighten** is on.
3. If the result is noticeably smaller than you want, switch **Crop** to
   **Stretch**.

To use only part of the photo (e.g. to leave out a drainage pipe), click on the input and while holding the left mouse button pressed, drag the mouse until you are satisfied with the selection. Select at least two repeats each way where you can. The tool will still work with one, but two gives it room to choose a cleaner cut.

### Sand, gravel, soil, grass, plaster

1. Open and press Space. Synth is usually right.
2. If one area of the result looks softer or blurrier than the rest, press
   **New seed** for a different fill, or switch to **Quick**. When you get a fill
   you like, note the number in the **Seed** box (it also appears in the status
   line as `Synth seed …`); typing it back in later gives exactly the same result.
3. If you can see large light or dark blotches repeating, raise **Even
   contrast** to around 0.5, and **Flatten** too if the blotches follow a
   lighting gradient.

### Stone walls and other irregular patterns

These sit between the two cases above. Leave **Fit to repeat** on: if there's
no repeat, it simply does nothing. If Synth produces a stone with a visible
cut through it, try a wider **Band** or a different seed.

### Wood

Wood grain has strong straight lines, so **Straighten** will level the grain if
the photo is slightly rotated. That costs a thin strip around the edge. If you
want the grain's natural slant kept, untick Straighten.

### A full material set (albedo, normal, roughness, height…)

Drop **one** of the maps, any of them. tileit looks in the same folder for the
others by name, so `Rock_Color.png`, `Rock_NormalGL.png` and
`Rock_Roughness.png` are picked up together. You can also select all of them
in **Open…** at once.

Once loaded:

- The buttons above the panes (**Albedo**, **Normal**, …) choose which map you
  see. **Tab** or the number keys **1–9** do the same.
- Every map gets exactly the same edit, so they stay lined up. The colour map
  makes all the decisions; Flatten and Even contrast only touch the colour map.
- Normal maps have their vectors corrected when the set is straightened.
- **Save all** writes every map as `name_tiled.png`.

Check the normal map at 3 × 3 before saving. A seam that's invisible in colour
can still show up in the lighting.

---

## 4. When it goes wrong

| What you see | Why | What to do |
|---|---|---|
| A visible line where tiles meet | The edge was only blended, not rebuilt | Use **Synth** rather than Quick, or widen the **Band** |
| Bricks too long, or half-bricks at the seam | No repeat was found, or it was measured wrong | Check the status line for `repeat …`. Turn on **Fit to repeat** and **Straighten**, or select a larger area |
| Doubled, faint joints near the seam | Blending of slightly misaligned copies (older versions, or no room to quilt) | Make sure the status line says `quilted`. If not, select an area that leaves some photo around it |
| A soft, blurry patch in the result | Synth copied from a smoother part of the photo | **New seed**, or switch to **Quick** |
| Large blotches repeating across the surface | Uneven lighting or contrast in the photo | Raise **Flatten** and/or **Even contrast** |
| Stripes of light and dark | A lighting gradient across the photo | Raise **Flatten** |
| Output has a different size than expected | **Output** is set to **Fitted** (the size after fitting to repeats or straightening) | Set **Output** to **Input**, or pick 1K, 2K or 4K |
| Bricks look slightly wider or taller than in the photo | The fitted tile wasn't square and was scaled to a square output | Use **Output: Fitted**, or **Stretch** so the fitted tile is closer to your selection's shape |
| A map was skipped when opening a set | It failed to load, or it's a different size from the others | All maps of a set must be the same size |
| `no regular repeat` on an obviously regular texture | The pattern is too long for the area, or the photo is in strong perspective | Select a larger area. Strongly converging lines aren't corrected yet |

---

## Reference

### Controls

| Control | What it does | Default |
|---|---|---|
| **Tile it** (Space) | Run. Settings changed afterwards re-run it when you let go of the control | |
| **Open…** | Pick one image or several maps of one material | |
| **Save** / **Save all** (Ctrl+S) | Write `name_tiled.png` next to each original | |
| **Save as…** | Choose the file name; other maps of the set go to the same folder | |
| **Quick / Synth** | How seams without a repeat are handled | Synth |
| **Band** | Width of the strip Synth rebuilds, as a share of the image | 0.06 |
| **Seed** | The current Synth seed. Click it, type a number, press Enter to use your own; the same seed and settings always give the same result | 1 |
| **New seed** | Next seed: a different Synth fill | |
| **Preview** | 1 × 1 to 6 × 6 copies in the output pane | 3 × 3 |
| **Swap sides** | Put the input on the right | off |
| **Tile input too** | Repeat the original as well, to compare seams | off |
| **Output** | Size of the saved tile: **Fitted** (as fitted), **Input** (same as the selection or photo), or 1K / 2K / 4K squares. Resizing wraps around, so it stays seamless | Input |
| **Map buttons** (Tab, 1–9) | Which map of a set is shown | |
| **Crop: Full / 1K / 2K / 4K** | A centred square selection of that size, or none | Full |
| **Fit to repeat** | Detect a repeat and fit the tile to it | on |
| **Crop / Stretch** | Trim to whole repeats, or scale slightly (≤ 15%) | Crop |
| **Straighten** | Rotate out a tilt of 0.3°–15° | on |
| **Trusted centre** | Central share of the photo that is measured and copied from | 65% |
| **Flatten** | Remove broad lighting gradients (colour map only) | 0 |
| **Even contrast** | Even out patchy contrast (colour map only) | 0 |
| **Scale** | Size of the area Flatten and Even contrast look at | 0.15 |

### Selecting part of the photo

| Action | Result |
|---|---|
| Drag on the input | Draw a selection |
| Drag inside the selection | Move it |
| Hold **Shift** while drawing | Keep it square |
| Right-click, **Esc**, or a plain click outside | Clear it |

On the input pane, the **bright amber frame** is your selection, the **thin amber
outline** is its trusted centre, and the **white frame** is the part the last
result was actually made from. The selection only works while **Tile input too**
is off.

### File naming for material sets

A map is recognised by the last word of its file name (ignoring a size tag
like `_2k`). Separators can be `_`, `-`, `.` or a space.

| Map | Names recognised |
|---|---|
| Albedo | `color`, `colour`, `albedo`, `basecolor`, `diffuse`, `diff`, `col` |
| Normal | `normal`, `normalgl`, `normaldx`, `nor_gl`, `nor_dx`, `nrm`, `nor` |
| Roughness | `roughness`, `rough`, `rgh` |
| Metallic | `metallic`, `metalness`, `metal` |
| Height | `height`, `displacement`, `disp`, `bump` |
| AO | `ao`, `ambientocclusion`, `occlusion` |
| Other (kept, treated as data) | `gloss`, `specular`, `arm`, `orm`, `opacity`, `mask` |

Single letters such as `_N` or `_R` aren't recognised; they're too easy to
confuse. Rename those files, or select them together in **Open…**.

### Command line

Everything in the window can be done from a terminal, which is handy for
batches:

```
tileit IN.png OUT.png                  one texture
tileit --set Rock_Color.png            a whole material set
tileit IN.png OUT.png --mode quick --flatten 0.5
tileit IN.png OUT.png --region 200,200,1600,1600 --repeat stretch
```

Run `tileit --help` for the full list of options.
