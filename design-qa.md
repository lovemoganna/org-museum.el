# Org Museum Wiki Design QA

## Visual truth

- Direction: Index Matrix, adapted to the existing Monokai palette.
- Reading density: 12px body copy, as explicitly requested.
- Source frames:
  - Homepage: `C:\Users\luoyu\.codex\generated_images\019fa940-a121-7980-9aed-911675c1eb67\call_MICDuzOMPQ0Oi4850JwiYMYz.png`
  - Article: `C:\Users\luoyu\.codex\generated_images\019fa940-a121-7980-9aed-911675c1eb67\call_99LTJbC854j1kxGyjCtdJbx8.png`
  - Graph: `C:\Users\luoyu\.codex\generated_images\019fa940-a121-7980-9aed-911675c1eb67\call_0V0N2i7m4ZL0hGFwz9xAZvn4.png`

## Comparison evidence

All desktop source and implementation frames were normalized to the same
1440×1024 viewport at DPR 1, then placed side by side in a single comparison
input (source left, implementation right).

- `test/qa/comparison-home-2880x1024.png`
- `test/qa/comparison-article-2880x1024.png`
- `test/qa/comparison-graph-2880x1024.png`
- `test/qa/implementation-home-resume-1440x1024.png`
- `test/qa/implementation-article-top-1440x1024.png`
- `test/qa/implementation-graph-zero-1440x1024.png`
- `test/qa/implementation-home-mobile-390x844.png`
- `test/qa/implementation-article-mobile-390x844.png`
- `test/qa/implementation-graph-mobile-390x844.png`

The implementation intentionally uses smaller typography than the generated
reference frames because the approved product requirement is a 12px reading
system. It also omits the reference's invented `AI` category and renders only
categories present in the exported fixture.

## Interaction and state evidence

- Homepage search returned the two real DuckDB pages and produced no browser
  errors.
- A visited article was persisted to IndexedDB `org-museum` and reappeared on
  the homepage at 75% with a valid heading URL. Reopening the link restored the
  stored reading position.
- The article fixture rendered five headings, one code block, one table,
  metadata attributes, navigation, backlinks, and local relationships without
  horizontal overflow.
- The zero-link graph rendered six isolated nodes, zero edges, the explicit
  empty state, a visible selected-node ring, and readable labels.
- The Ontology filter dimmed four nodes and retained two; the DuckDB search
  narrowed the active result to one node.
- At 390×844, homepage, article, both navigation drawers, and graph had no
  horizontal overflow. The graph uses a mobile-only single-column node layout
  so long titles do not collide with the empty state.
- Browser console logs were empty for homepage, article, and graph checks.

## Resolved findings

- P1: a fresh homepage left the continue-reading area visually blank. Fixed
  with an explicit no-history state and a recent-update action.
- P1: the article title wrapped and sticky rails accumulated the top offset.
  Fixed by widening the title measure and anchoring rails inside the fixed
  reading viewport.
- P1: graph rendering depended on a remote D3 resource during offline QA.
  Fixed by exercising the exporter's local resource deployment.
- P2: long graph labels clipped at the right edge. Fixed with edge-aware text
  anchoring and bounded truncation.
- P2: mobile graph labels collided around the zero-link empty state. Fixed
  with a narrow-screen single-column distribution and a central gap.
- P2: the selected isolated node lacked contrast. Fixed with a Monokai pink
  ring and dark center.

## Final assessment

No open P0, P1, or P2 visual or interaction defects remain in the checked
states.

final result: passed
