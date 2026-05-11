Use the Terminal Flappy Builder agent for this task.

Implement the game defined in `docs/requirements.md`.

Requirements:
- Go project runnable with `go run .`
- playable terminal loop with clear controls and smooth frame updates
- no external assets
- keep gameplay logic readable and testable
- add or update a short `README.md` with controls and run steps

Visual + feel targets (important):
- Recreate a retro pixel-art terminal vibe similar to classic Flappy Bird:
	- bright sky field
	- layered cloud/horizon banding
	- city/building silhouette layer
	- green ground strip
	- chunky pipe columns
	- expressive bird and clear score HUD
	- bird should look like a pixel character, not a single plain symbol:
		- **BASELINE STATUS: this sprite/layout is the first good version**; treat it as the default accepted bird baseline unless the user explicitly asks to change it
		- **target sprite footprint: 12 cols × 3 rows** for the visible sprite silhouette; the bird must read as slim in Y and longer in X
		- **CRITICAL: bird MUST FACE AND FLY RIGHTWARD** at ALL times
		- **CRITICAL: every bird body/head cell MUST set an explicit background color** — never render body or head as outlines on the sky background
		- bird should read closer to the classic reference: mustard/yellow body, pale front face block, large white wing block, white eye with dark pupil, short coral/red beak on RIGHT, compact dark rear tail wedge on LEFT
		- any bird-adjacent cell that is not opaque body/face/wing/tail must use the current scene background color, NOT terminal transparency; approximate layer sampling is acceptable and does not need pixel-perfect masking
		- **preview-first workflow**: before changing the game sprite, validate the shape by running `doc/tutorial-agents/flappy-bird-go/tools/bird-preview` and only then copy the accepted layout into the game
		- if a future iteration looks worse than this baseline, revert to this first good version before making further changes
		- **source-of-truth rule**: the explicit frame matrices and per-cell style legend in this document are canonical; the preview tool should mirror them, not replace them
		- do not compress, rescale, rotate, recolor, or simplify the bird when implementing it; reuse the same per-pose cell layout defined below

		- **Rendering approach — background-color-first**:
		  ```
		  The BACKGROUND COLOR of each cell determines the bird's appearance.
		  Foreground glyphs add shape detail on top, but the bg color makes it OPAQUE and SOLID.

		  Never leave bird-adjacent cells with an unset/default terminal background.
		  Instead, implement a small scene background sampler such as:
		    sceneBG(row, col, worldX) -> one of {SkyUpper, SkyLower, CloudBand, SkylineAir, BuildingFace, GroundTop, GroundFill}
		  This sampler may be approximate and layer-based; it does NOT need per-pixel precision.
		  The goal is: beak/wing edge/tail edge cells blend into the active game scene rather than showing black terminal holes.

		  Color constants (implement in palette file):
		    BirdBody   = #D8AA00  (term 178)  mustard yellow — main torso
		    BirdHead   = #F7F3E8  (term 255)  pale cream     — front face block around the eye
		    BirdWing   = #FFFFFF  (term 231)  white          — large wing cells like the reference bird
		    BirdTail   = #6F4A12  (term 94)   dark ochre     — compact tail wedge cells
		    BirdEyeBg  = #FFFFFF  (term 231)  white          — eye cell background
		    BirdEyeFg  = #1A1A1A  (term 233)  near-black     — pupil foreground
		    BirdBeak   = #E85D75  (term 204)  coral red      — beak foreground on scene background

		  Glyph usage (foreground ON TOP of the background):
		    body cell  :  ' ' (space) with BirdBody bg  — solid yellow fill
		    head cell  :  ' ' (space) with BirdHead bg  — solid pale face fill
		    top body edge : Nerd Font `\uE0BE` / `\uE0BC` style triangular edge glyphs if available; fallback `◣` `◢`
		    bottom body edge: matching lower triangular edge glyphs; fallback `◥` `◤`
		    eye cell   :  '●' (U+25CF) fg=BirdEyeFg, bg=BirdEyeBg — white cell + dark dot pupil
		    beak cell  :  Nerd Font `\uEB70` if available; fallback `›` or `▶` with CORAL fg on scene-sampled bg
		    tail cell  :  use one compact attached tail wedge: a brown square cell plus one subtle brown triangle cell integrated into the rear-left body silhouette
		    wing up    :  two-row wing shape shifted one cell toward the head: upper row = lower-right-triangle + square; lower row = lower-right-triangle only
		    wing mid   :  side wing shifted one cell toward the head: rect + square silhouette attached to the body's left-middle
		    wing down  :  two-row wing shape shifted one cell toward the head: upper row = upper-right-triangle + square; lower row = upper-right-triangle only
		  ```

		- **Sprite layout** — 12 cols × 3 rows (B=BirdBody bg, H=BirdHead bg, W=wing, T=tail, scene=scene-sampled background):
		  ```
		  WINGS UP (ascending):
		    col:  0      1      2      3      4      5      6      7      8      9     10    11
		  row0: [scene][scene] [scene] [scene] [ Wup-tri ] [ Wup-square ] [ B^ ] [ B^ ] [ H^ ] [ H^ ] [scene][scene]
		  row1: [scene][scene] [scene] [scene] [ Wup-tri ] [ Tail-square ] [ B  ] [ B  ] [ H  ] [ eye] [ H  ] [ bk ]
		  row2: [scene][scene] [scene] [scene] [ Tail-tri ] [ Bv ] [ Bv ] [ Bv ] [ Hv ] [ Hv ] [scene][scene]

		  WINGS MID (neutral):
		    col:  0      1      2      3      4      5      6      7      8      9     10    11
		  row0: [scene][scene] [scene] [scene] [scene] [ B^ ] [ B^ ] [ B^ ] [ H^ ] [ H^ ] [scene][scene]
		  row1: [scene][scene] [scene] [ Wmid-rect ] [ Wmid-square ] [ Tail-square ] [ B  ] [ B  ] [ H  ] [ eye] [ H  ] [ bk ]
		  row2: [scene][scene] [scene] [scene] [ Tail-tri ] [ Bv ] [ Bv ] [ Bv ] [ Hv ] [ Hv ] [scene][scene]

		  WINGS DOWN (descending):
		    col:  0      1      2      3      4      5      6      7      8      9     10    11
		  row0: [scene][scene] [scene] [scene] [scene] [ B^ ] [ B^ ] [ B^ ] [ H^ ] [ H^ ] [scene][scene]
		  row1: [scene][scene] [scene] [ Wdown-tri ] [ Wdown-square ] [ Tail-square ] [ B  ] [ B  ] [ H  ] [ eye] [ H  ] [ bk ]
		  row2: [scene][scene] [scene] [scene] [ Wdown-tri ] [ Tail-tri ] [ Bv ] [ Bv ] [ Hv ] [ Hv ] [scene][scene]
		  ```
		  Key: `B` = BirdBody bg (mustard yellow), `H` = BirdHead bg (pale face block), `W` = BirdWing fg/bg (white on scene),
		       `Tail-square/Tail-tri` = compact dark rear tail wedge, `eye` = white bg + dark pupil, `bk` = coral beak on scene,
		       `B^/H^` = upper triangular edge glyphs, `Bv/Hv` = lower triangular edge glyphs

		- **solid fill rule**: body and head interior cells use `' '` (space) with background color set; the triangle glyphs only smooth the top/bottom silhouette, they do not replace the opaque fill
		- **tail rule**: tail is a compact attached brown wedge at the rear-left of the body, made from one small brown square plus one subtle brown triangle; do not use detached `\\` and `/` marks
		- **body edge rule**: use Nerd Font / Powerline-style triangle edge glyphs (the `e0be`, `e0bc` family) for the top and bottom body/head edges when available; fallback to geometric triangles if Nerd Font is unavailable
		- **beak rule**: use `▶`; the beak is one cell wide and one row tall at the far-right center, with CORAL foreground and scene-sampled background
		- **wing size rule**: wing span must be at least the same apparent size as the body silhouette; a tiny 1–2 cell wing is a failure
		- **wing shape rule**: show one wing using the exact two-row layouts below, angled and pointed, not square; do NOT repeat triangles across the whole body edge or create a centipede/comb silhouette
		- **body corner rule**: soften the body's lower-left corner with ONE subtle upper-right triangle glyph in the lower-left body corner; this should reduce squareness without looking like a spike
		- **wing anchor rule**: shift the wing one cell toward the head so it reads as a body-mounted wing, not a tail-side fin
		- **body proportion rule**: body must be slim vertically; avoid fish-like 5-row or boxy silhouettes
		- **background sampling rule**: every `scene` cell and every edge-detail cell (`bk`, `Tail-tri`, wing triangles, top/bottom edge triangles) must call the scene background sampler so the bird blends into sky, cloud band, skyline air, building faces, or ground instead of falling back to the terminal default background
		- **reference-match rule**: bias the sprite toward the supplied reference images: the front should read as a pale face block, the wing should read white and chunky, and the beak should read coral/red instead of brown
		- **glyph fallback**: if a Nerd Font glyph renders as tofu or double-width, fall back to the listed geometric triangles or slash characters while preserving the same layout and proportions
		- 3 flap poses driven by vertical velocity:
			- WINGS UP: top row = lower-right-triangle + square; next row = lower-right-triangle only, both attached near the body middle
			- WINGS MID: side wing = rect + square attached near the body middle
			- WINGS DOWN: top of wing = upper-right-triangle + square; bottom = upper-right-triangle only, attached near the body middle
		- bird orientation MUST REMAIN RIGHTWARD in all poses
	- scene should visibly separate layers:
		- top sky area
		- visible cloud clusters in the sky itself, above the horizon band; clouds should read as soft white/light-cream puffs made from 2-5 joined blobs or block groups, not single isolated dots
		- cloud/horizon transition band with a light aqua middle band similar to the reference scene
			- keep clouds sparse: usually 2-5 cloud groups on screen, unevenly spaced, with varied widths around 6-18 cols and heights around 2-4 rows
			- clouds should drift more slowly than pipes and can parallax slightly against the sky
			- avoid full-width repeating cloud motifs or evenly tiled patterns
		- building skyline band: TALL, WIDE, LIGHT-COLORED buildings (white/light-gray/dark-gray bodies, NOT dark silhouettes)
			- individual buildings: 4–10 cols wide, heights 6–18 rows, extending up into the lower sky for visual drama
			- color palette: white (#FFFFFF / term 231), light gray (#D0D0D0 / term 252), dark gray (#808080 / term 244), cool blue outline/window accents (#5A8FD8 / term 68) — use contrasting shades between adjacent buildings
			- window details: small □ ▪ ▫ glyphs in a darker or blue-accent shade on the building face
		- bottom ground strip with darker top edge
		- pipes should match the reference style: vivid green columns with a narrow white highlight stripe on the right edge and a squared lip/cap transition near the opening
- Prioritize readability in common macOS terminals (kitty, iTerm2, Terminal.app):
	- avoid tiny glyph-dependent art that breaks with font differences
	- provide sensible fallback characters/colors when true color is unavailable
- Keep motion readable and lively:
	- steady frame pacing
	- responsive flap input
	- visible obstacle movement cadence
	- **anti-flicker rendering is mandatory**: use Bubble Tea's full-screen alt-screen mode (`tea.WithAltScreen()`); never clear and redraw line-by-line; build the entire frame as a single string and return it from `View()` in one pass; do not use ANSI cursor movement or partial redraws outside of Bubble Tea's own diff/render cycle

Gameplay tuning targets (implement as named constants):
- fixed update step: 33 ms (~30 FPS) or equivalent deterministic loop
- gravity: default around +32 rows/s^2
- flap impulse: default around -11 rows/s
- bird vertical velocity clamp: about -14 to +14 rows/s
- pipe horizontal speed: start near 18 cols/s, scale toward ~24 cols/s as survival time increases
- spawn interval: derived from horizontal gap distance (see below); add ±20% random jitter per spawn
- **pipe width: vary per pipe between 8 and 16 cols** (not 2–4); wider pipes are more visible and feel more like the original game
- **horizontal gap between pipes: 32 to 64 cols** (measured from right edge of one pipe to left edge of the next); this is the space the bird flies through horizontally; derive spawn interval as: gap_cols / pipe_speed; jitter the gap_cols ±10 cols per spawn so spacing feels irregular
- gap size (vertical): preview bird sprite is 3 rows tall visually, but allow extra clearance for readable gameplay; **base vertical gap starts at 14 rows**, reduces toward 10 rows as difficulty increases, **never below 8 rows**; add ±1–2 row random jitter per pipe
- gap vertical position: randomise the gap center position within safe bounds each spawn; must NOT appear at the same vertical position repeatedly
- scoring: +1 per pipe pair fully passed

Gameplay feel calibration:
- Keep defaults close to the targets above so first run already feels right.
- Expose all tuning constants in one place (for example `internal/game/tuning.go`) with short comments.
- Add a brief "how to tune difficulty" note to README.

Art/style calibration:
- Keep all sprite and scene glyph patterns in code as reusable templates (no external assets).
- Expose bird animation frame definitions and color palette constants in one file for quick iteration.
- Reuse the exact accepted frame definitions written in this document as the starting contents of that file.
- Prefer block/box drawing chars that remain legible across kitty and common macOS terminal fonts.

Implementation guidance:
- Use Bubble Tea (`github.com/charmbracelet/bubbletea`) as the required TUI framework.
- Optional helpers: Lip Gloss for styling if useful, but avoid overcomplicated style layers.
- Keep rendering and gameplay logic separated so core rules can be tested without terminal IO.
- Prefer small, focused files/functions over a monolithic main loop.
- Include a minimal set of unit tests for physics, collisions, and score progression.
- Add deterministic tests that validate at least:
	- velocity integration and flap impulse behavior over multiple ticks
	- collision at pipe edge/gap boundary cases
	- spawn cadence progression and gap/speed ramp limits

Visual guardrails (to prevent common bad output):
- Do not render background as many full-width alternating horizontal bands.
- Keep clouds sparse and clustered; avoid line-by-line repeating motifs across the whole width.
- Clouds must be visibly present in the upper sky area; a scene with only a flat cloud band and no cloud puffs is incomplete.
- **Pipe size rules** (violations are a visual/gameplay failure):
	- pipe width MUST be 8–16 cols (thin 2–4 col pipes are a failure)
	- horizontal gap between pipes (right edge to left edge) MUST be 32–64 cols; never closer
	- consecutive pipe spawn horizontal gaps MUST differ (±10 col jitter; never perfectly uniform)
	- consecutive gap heights MUST differ (±1–2 row jitter per pipe)
	- consecutive gap vertical positions MUST differ (randomise center within playable bounds)
- **Anti-flicker rule**: use `tea.WithAltScreen()`, compose the full frame in `View()` as one string, never write partial ANSI escape sequences or clear-screen calls outside Bubble Tea's render path
- Buildings must be TALL (6–18 rows), WIDE (4–10 cols each), and LIGHT-COLORED (white/gray palette, never dark/black); short or dark building stubs are a visual failure.
- Ensure HUD text sits on a high-contrast backing strip or shadowed text treatment.
- Bird and pipes must remain visually dominant over background decoration.
- Bird-adjacent negative space must inherit scene colors; black terminal-background holes around the bird are a rendering failure.
- Enforce layer row budgets (based on current terminal height, with +/-1 row tolerance):
	- top HUD strip: exactly 1 row
	- sky main area: 55% to 65% of playable height
	- cloud/horizon band: 8% to 14%
	- skyline/buildings band: 16% to 24%
	- ground strip: 8% to 12% (minimum 2 rows)
- On small terminals, keep layer order and gameplay readability even if exact percentages are relaxed.

Use these helper scripts when relevant:
- `./scripts/run-game.sh`
- `./scripts/check-quality.sh`

Definition of done:
- Runs with `go run .` on macOS.
- Game loop is fully playable via keyboard.
- Uses Bubble Tea as the TUI/event-loop library.
- Visual style clearly matches the retro reference direction.
- Bird, sky, clouds, buildings, and ground are all visibly represented and stylistically cohesive.
- Background avoids heavy stripe artifacts and keeps gameplay elements readable at a glance.
- Implemented scene uses explicit row-budget constants/helpers (not ad-hoc per-line loops).
- README explains controls, run steps, and any terminal/font caveats.
- README includes the default tuning constants and where to change them.
- Quality script passes, or failures are documented with clear next actions.

Do not over-engineer this; keep the implementation tutorial-friendly.
