---
name: design-brief
description: Write or read a product brief and design brief before building or changing any user-facing UI, then check the result in a real browser. Use when asked to design, redesign, restyle, polish or critique a page, screen, app, landing page or component, or before starting frontend work whose look and feel is not yet decided. Not for HTML artifacts or charts; those are artifact-design and dataviz.
---

# Design brief

Most weak UI comes from building before deciding who it is for and how it
should feel. Settle that in two short files, then build against them and
check the rendered result yourself.

## 1. Product brief: `PRODUCT.md`

Look for `PRODUCT.md` at the repo or app root. If it exists, read it and
follow it. If not, copy `templates/PRODUCT.md` from this skill and fill it
in from the code, README and the request. Ask the owner only for what you
cannot infer: usually the audience, the tone and the anti-references.

It answers: who uses this, the one job they come to do, three words for the
personality, what it must not look like, and the accessibility floor.

## 2. Design brief: `DESIGN.md`

Same rule: read it if present, else start from `templates/DESIGN.md`.
Tokens (colour, type scale, spacing, radius, shadow, motion) live in the
YAML frontmatter so code can use them; prose below explains the choices.

- Derive tokens from what the codebase already uses before inventing new
  ones. Two greys that differ by 2% are one token.
- Emit tokens into the stack's own format: a Tailwind theme
  (`@theme` in CSS for v4, `theme.extend` for v3) or CSS custom properties.
  Components use tokens, never raw hex or pixel values.
- Change a token in `DESIGN.md` first, then in code, in the same PR.

## 3. Pick a mode per surface

One app has several surfaces; each gets one mode, recorded in `DESIGN.md`.

| Mode | The user wants to | Favour |
|---|---|---|
| Persuade | be convinced to sign up, buy, trust | one message per screen, a clear call to action, real proof |
| Operate | get a task done fast, often daily | density, keyboard paths, stable layout, quiet colour |
| Read | understand long content | measure of 60–75 characters, strong type hierarchy, few distractions |
| Experience | enjoy or explore | motion and atmosphere, but never at the cost of control |

A dashboard styled for Persuade, or a landing page styled for Operate, is
the most common mismatch. Name the mode before choosing layout.

## 4. Craft floor: do not ship these

- A gradient hero with a vague headline and two buttons.
- Rows of identical cards with an icon, a title and two lines of filler.
- Purple-to-blue gradients, glassmorphism or glow on everything.
- Logo walls, fake testimonials or invented metrics as decoration.
- Emoji as icons; mixed icon sets.
- Every element centred; every corner the same large radius.
- Placeholder copy ("Lorem ipsum", "Feature one") left in.
- Contrast below WCAG AA, or focus states removed.

If the brief asks for one of these on purpose, it wins; say so in the PR.

## 5. Verify in a real browser

Tests do not show whether a page looks right. Before calling the work done:

1. Capture **before** screenshots of each touched surface first, before
   editing.
2. Run the app and open it in a browser you control: the T3 Code preview
   tools in a T3 thread, otherwise Playwright.
3. Walk the main flow as a user would, at a phone width (390px) and a
   desktop width (1440px), in light and dark if both exist.
4. Check against the brief: mode, personality, craft floor, keyboard focus,
   no horizontal scroll, no layout shift on load.
5. Fix what is rough, then capture **after** screenshots at the same sizes.
6. Attach before and after images to the PR. Motion changes get a short
   recording instead.

Report anything you could not check (no dev server, auth wall) in the PR's
*Verified* line rather than implying it was seen.
