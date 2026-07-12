# First-class composite widgets: a `build` interface method with auto-rebuild

Status: **Parts 1 + 2 implemented, with Part 3 resolved as Option A (naive
replace)** — interface `build` method, build phase in flush, single-child
passthrough layout default, `Element.request_build` (release deferred to the
build pass), `request_paint` → `request_build` routing on paint-less build
widgets (so `@modify` is kind-aware), nested-composite rebuild cascade.
Verified by the unit tests (`c3c test unittest`, `test/unit/build_test.c3`).
Positional
reconciliation (Phase 2's `reconcile` hook) and keyed reconciliation (Phase 3)
remain unimplemented by design — revisit only if real usage produces stateful
widgets inside rebuilt composites.

Goal: make the composite-widget pattern (today done by hand in
`test/composite.c3`) a first-class part of the framework — a `build` interface
method the framework calls automatically, and re-invokes when the widget's state
is invalidated, so a data change regenerates the subtree the way a Flutter
`setState` does.

---

## The frame: this is a small Flutter reconciler

Two very different-sized things are bundled together. Separating them is the
whole game:

1. **A `build` interface method + auto-invalidation plumbing** — small,
   mechanical, uncontroversial.
2. **What happens to the *existing* subtree when `build` re-runs** —
   reconciliation. This is the entire hard problem; Flutter's element tree
   exists almost solely to answer it.

---

## Part 1 — The ergonomic prize (why it's worth doing)

Made first-class, a composite collapses to *just* `build`; the framework
supplies the rest:

- **Initial build** — `attach_node` sees the widget implements `build`, sets
  `dirty.build`, and the next flush builds it. The composite is created
  childless; no children are passed to `@node`.
- **Default layout** — if a widget has `build` but no `layout`, `layout_element`
  does single-child passthrough (delegate to `child[0]`, place at `{0,0}`).
  Today's `StatCard.layout` boilerplate disappears.
- **Paint** — already free: the composite has no `paint`, so the emit pass just
  recurses into the built children.

End state: `struct StatCard(Widget){ float value; Color accent; }` plus
`fn Element* StatCard.build(...)` and nothing else. That alone justifies the
feature even before rebuild exists.

---

## Part 2 — The plumbing (the easy 80%)

Mirror the existing invalidation machinery exactly.

- `DirtyFlags` (today `bitstruct : char { bool layout; bool paint; }`) gains
  `bool build;`.
- `Ui` gains `bool build_pending;` (next to `layout_pending` / `paint_pending`).
- `fn void Element.request_build(&self)` — sets `dirty.build`, walks parents
  marking the descend path (exactly like `request_layout`), sets `build_pending`
  + `frame_requested`.
- `Ui.flush()` gains a **build phase before layout**:

  ```
  if (build_pending) { rebuild_dirty(root); build_pending = false; }
  if (layout_pending) { ... }   // unchanged
  if (paint_pending)  { ... }   // unchanged
  ```

  Rebuilding an element marks it `dirty.layout`, so the layout phase follows
  naturally. Phase order build → layout → paint is Flutter's, and it drops in
  cleanly because invalidation is already flag-and-descend.

**Trigger ergonomics.** `request_build` is the primitive. The nice unification:
a composite has no meaningful "repaint", so **`request_paint` on a build-widget
could route to `request_build`** — then the existing
`ui.@modify(StatCard; c){ c.value = … }` "just works" and regenerates the card.
Cost: one `if (&elem.widget.build)` check. (Alternative: a separate `@rebuild`
sugar mirroring `@modify`.)

None of Part 1 or Part 2 is contentious. The real question is Part 3.

---

## Part 3 — What rebuild does to the old subtree (the whole design)

The fact that makes CUI **different from Flutter**, and cuts both ways:

> **CUI has no Widget/State split.** The widget struct is mutable and lives *on*
> the element as an owned copy (`element.widget`, `owns_widget`). It is
> simultaneously the config (what `build` produces) and the state (what event
> handlers mutate).

**The good half.** A composite's *own* state is on the composite's *own*
element. Rebuild regenerates its **children**, not itself — so `StatCard.value`
survives its own rebuilds for free. That is exactly Flutter's "State outlives
rebuild", with zero machinery.

**The hard half.** Descendant state lives on descendant elements, and we must
decide what happens to them on rebuild.

### Option A — naive replace

`release` the old children (the existing path: fires `unmount`, frees owned
widgets, recycles elements, clears `hovered`/`captured`/`focused`/id pointers),
then attach the freshly-built subtree.

- **Pro:** trivial, correct, reuses existing `release`. No reconciler.
- **Con:** every rebuild destroys all descendant element state — a nested
  `Button`'s hover, a child `Dial`'s drag value, focus, and any `Element*` the
  app cached into the subtree (now dangling → recycled). Churns the free-list.

### Option B — positional reconciliation

Diff new-built against old by (type, position): same type at index *i* → keep the
old element and recurse into its children; else replace. Discard the
freshly-built elements that matched.

- **Pro:** preserves descendant elements (and thus focus/hover/handles) whenever
  the subtree *shape* is stable — the overwhelmingly common case. This is what
  "close to true Flutter setState" actually means.
- **Con — two subtleties, one genuinely nasty:**
  - **Alloc-then-discard.** `build` returns *real* elements (via `@node`), not
    Flutter's cheap immutable Widget descriptions. Reconciling means allocating a
    subtree just to diff it against the old and throw most of it away. The
    free-list softens this, but it is inherent to the fact that **CUI conflates
    "description" and "node".**
  - **The config/state merge problem (the deep one).** Keeping an old `Button`
    element that now has a *new* built `Button{style=…, on_click=…}` config means
    updating its config **without** clobbering its runtime state
    (`hovered`, `held`). But there is no declared distinction between config
    fields and state fields — it is one struct. `*old.widget = *new.widget`
    resets hover. **Flutter's Widget/State split exists precisely to make this
    clean; without it, generic reconciliation cannot know what to preserve.**

So Option B is not just "more code" — it runs straight into the design
consequence of having no Widget/State split. That is the real finding.

---

## Part 4 — Recommendation: a coherent v1 that dodges the merge problem

Ship **Part 1 + Part 2 + Option A (naive replace)**, but pin it to an explicit,
honest philosophy rather than treating naive replace as a temporary hack:

> **`build` is a pure function of the composite's own state. Rebuild regenerates
> children from scratch. Anything with independent state is either (a) lifted
> into the composite's own fields — where it survives rebuild and is passed down
> as config — or (b) mounted as a stable sibling you do not regenerate.**

Under that rule naive replace is *correct*, not lossy: there is no descendant
state to lose, because the pattern says do not put it there. It is small, ships
the whole ergonomic win, is internally consistent, and matches how the
data-card motivating case actually works.

**Phase 2 = positional reconciliation**, only if real usage produces composites
with stateful children that must survive a parent rebuild. When we do it, confront
the merge problem head-on with an explicit escape hatch rather than magic — most
likely an optional `reconcile` hook:

```c3
fn void reconcile(Element* elem, <same-type>* rebuilt) @optional;
// self.style = rebuilt.style;   // take config
// (leave self.hovered / self.held untouched — keep state)
```

No hook → full overwrite (correct for stateless widgets). This keeps the
config/state distinction **per-widget and opt-in**, which fits CUI's
"no global split" character far better than importing Flutter's mandatory State
object.

**Phase 3 (probably never)** — full keyed reconciliation with reorder / insert /
remove, using the existing `Element.id` field as the key. Defer until something
concrete demands list reconciliation; it is the tail of the effort for a
fraction of the value.

---

## Part 5 — Risks / edges to keep on the radar

- **Rebuild-in-rebuild loop.** Clear `dirty.build` *before* calling `build`; if
  `build` re-dirties, it rebuilds next frame (or assert). Same discipline as not
  calling `request_layout` from inside `layout`.
- **`build` must be pure** — no side effects but producing the subtree. Document.
- **Dangling handles (Phase 1).** Any `Element*` an app cached into a rebuilt
  subtree is invalid after rebuild. The Part 4 philosophy makes this a non-issue
  (do not reach into regenerated children); state it loudly.
- **`@node` children on a build-widget.** Define it — likely an error / ignored,
  since `build` owns the children.
- **Focus / hover / capture loss** on naive rebuild — a symptom of the same
  descendant-state issue; the philosophy sidesteps it, reconciliation fixes it.

---

## The one decision that drives everything

How complete must v1 feel?

- **Naive-replace-first (recommended)** — small, coherent, ships the ergonomics
  + `setState`, with the "lift state up" rule. Reconciliation later, only if
  needed.
- **Straight to positional reconciliation** — genuinely closer to Flutter on day
  one, but signs up now for the alloc-then-discard cost *and* a real answer to
  the config/state merge problem (the `reconcile` hook): a meaningfully bigger
  design + implementation.

**The question that settles the scope:** do you foresee **stateful widgets living
inside rebuilt composites** (nested buttons, fields, dials)? If no, naive replace
is correct and clean. If yes, that is the trigger for reconciliation and the
`reconcile` hook.

---

## Concrete change list (for reference, when we commit to a phase)

Phase 1 (naive replace):

- `src/ui.c3`
  - `DirtyFlags`: add `bool build;`.
  - `Ui`: add `bool build_pending;`.
  - `Widget` interface: add `fn Element* build(Element* elem) @optional;`.
  - `Element.request_build(&self)` — flag + parent descend + pending + frame.
  - `attach_node`: if `&widget.build`, set `dirty.build = true`, `build_pending`.
  - `flush()`: add build phase before layout; `rebuild_dirty(root)` walks the
    descend path, and at each `dirty.build` element: `release` current children,
    call `widget.build(elem)`, attach result, mark `dirty.layout`.
  - `layout_element`: default branch — if `&widget.build` and no `&widget.layout`,
    single-child passthrough to `child[0]`.
  - Optionally: `request_paint` routes to `request_build` when `&widget.build`.
- `test/composite.c3`: drop the lazy-build `StatCard.layout`; keep only
  `StatCard.build`; add a button/interaction that mutates `value` and calls
  `request_build` (or `@modify`) to demonstrate auto-rebuild.
- `README.md`: fold the "Composite widgets" section over to the `build` method;
  document the "build is a pure function of the composite's own state" rule.

Phase 2 (positional reconciliation), additive:

- Replace `rebuild_dirty`'s naive release+attach with a positional diff
  (match by widget type + position; recurse; release/create only the delta).
- Add optional `reconcile(elem, rebuilt*)` hook; default = overwrite widget data.
- Document the state-preservation guarantee (stable subtree shape) and its edge
  (reorder/length change without keys → Phase 3).
