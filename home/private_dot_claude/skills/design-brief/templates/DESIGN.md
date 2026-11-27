---
# Design tokens. Code reads these; components never hard-code values.
# Map to a Tailwind theme (@theme in v4, theme.extend in v3) or CSS custom properties.
color:
  bg: "#ffffff"
  surface: "#f6f7f9"
  text: "#14171f"
  muted: "#5b6270"
  border: "#e2e5ea"
  accent: "#2f6fed"
  accent-text: "#ffffff"
  danger: "#c8372d"
  success: "#1f8a4c"
color-dark:
  bg: "#0f1115"
  surface: "#181b21"
  text: "#e8eaee"
  muted: "#9aa1ad"
  border: "#2a2f38"
  accent: "#6d9bff"
  accent-text: "#0f1115"
  danger: "#ff6b5e"
  success: "#4cc282"
font:
  sans: "Inter, system-ui, sans-serif"
  mono: "ui-monospace, SFMono-Regular, monospace"
type-scale:   # rem; ratio 1.25
  xs: 0.75
  sm: 0.875
  base: 1
  lg: 1.25
  xl: 1.563
  2xl: 1.953
  3xl: 2.441
line-height:
  tight: 1.2
  body: 1.55
space:        # rem; 4px base grid
  1: 0.25
  2: 0.5
  3: 0.75
  4: 1
  6: 1.5
  8: 2
  12: 3
  16: 4
radius:
  sm: 4px
  md: 8px
  full: 9999px
shadow:
  sm: "0 1px 2px rgb(0 0 0 / 0.06)"
  md: "0 4px 12px rgb(0 0 0 / 0.08)"
motion:
  fast: 120ms
  base: 200ms
  easing: "cubic-bezier(0.2, 0, 0, 1)"
breakpoints:
  sm: 640px
  md: 768px
  lg: 1024px
  xl: 1280px
---

# Design brief

<!-- The values above are placeholders. Replace them with what the codebase
already uses, then explain the choices below. Read PRODUCT.md first. -->

## Direction

<Two or three sentences: how the personality in PRODUCT.md shows up
visually. What is loud, what stays quiet.>

## Modes by surface

| Surface | Mode | Layout rule |
|---|---|---|
| <surface> | <persuade / operate / read / experience> | <e.g. single column, max 72ch> |

## Colour

<Where the accent is allowed, and where it is not. How danger and success
are used. Which pairs were checked for AA contrast.>

## Type

<Which scale steps headings and body use. Where mono appears. Measure for
long text.>

## Layout and spacing

<Grid or max widths, density per mode, how sections are separated.>

## Components

<Buttons, inputs, cards, tables: the variants that exist and when each is
used. Anything not listed here should not be invented ad hoc.>

## Motion

<What animates and why. Everything respects prefers-reduced-motion.>

## Exceptions to the craft floor

<Any banned pattern the brief deliberately keeps, with the reason. Usually
empty.>
