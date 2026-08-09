// Shared fixtures for the headless unit tests (c3c test unittest). Everything
// here runs without a renderer or window: the Ui core, layout, paint caching,
// and input dispatch are all plain CPU code.
module cui_tests;
import cui;
import std::math;
import std::core::test;

const Vec2 WINDOW = { 400.0, 100.0 };

macro void eq_vec2(Vec2 got, Vec2 want)
{
	test::eq(got.x, want.x);
	test::eq(got.y, want.y);
}

// Feed one input frame the way an embedder would.
fn void frame(Ui* ui, Vec2 mouse, bool left = false, float scroll = 0, Key[] keys = {}, bool right = false)
{
	ui.process_input({
		.mouse = mouse,
		.buttons = { left, right, false },
		.scroll = scroll,
		.keys_down = keys,
	}, 0.016f);
}

// ---------------------------------------------------------------------------
// Probe: a leaf with a preferred size that counts layout() and paint() calls —
// proves what the caches DIDN'T re-run.

struct Probe (Widget)
{
	Vec2 pref;
	int* layouts;
	int* paints;
}

fn Vec2 Probe.layout(&self, Element* elem, Constraints c) @dynamic
{
	if (self.layouts) (*self.layouts)++;
	return c.constrain(self.pref);
}

fn void Probe.paint(&self, Element* elem, Painter* painter) @dynamic
{
	if (self.paints) (*self.paints)++;
}

// ---------------------------------------------------------------------------
// EventProbe: records every event callback into a caller-owned EventRecord.
// Lays out as a fixed-size box; wraps an optional single child (so bubbling
// through nested probes can be tested).

struct EventRecord
{
	int enters;
	int leaves;
	int presses;
	int releases;
	int moves;
	int scrolls;
	int key_downs;
	int key_ups;
	int updates;
	Vec2 last_pos;
	float last_scroll;
	Key last_key;

	// Whether EventProbe.watch was held when the last key arrived — what an
	// application asks to tell a chord from the bare key.
	bool watched_at_key;
	bool consume_mouse;
	bool consume_key;
}

struct EventProbe (Widget)
{
	Vec2 pref;
	EventRecord* rec;
	bool transparent; // sets elem.ignores_pointer from layout(), like Label does
	Key watch; // polled from on_key into `watched_at_key`; EMPTY is never held
}

fn Vec2 EventProbe.layout(&self, Element* elem, Constraints c) @dynamic
{
	elem.ignores_pointer = self.transparent;
	Vec2 size = c.constrain(self.pref);
	if (elem.children.len() > 0)
	{
		elem.layout_child(0, { .min = {0, 0}, .max = size });
		elem.place_child(0, {0, 0});
	}
	return size;
}

fn bool EventProbe.on_mouse(&self, Element* elem, MouseEvent event) @dynamic
{
	switch (event.kind)
	{
		case PRESS: self.rec.presses++;
		case RELEASE: self.rec.releases++;
		case MOVE: self.rec.moves++;
		case SCROLL:
			self.rec.scrolls++;
			self.rec.last_scroll = event.scroll;
	}
	self.rec.last_pos = event.pos;
	return self.rec.consume_mouse;
}

fn void EventProbe.on_hover(&self, Element* elem, bool entered) @dynamic
{
	if (entered)
	{
		self.rec.enters++;
	}
	else
	{
		self.rec.leaves++;
	}
}

fn bool EventProbe.on_key(&self, Element* elem, KeyEvent event) @dynamic
{
	if (event.down)
	{
		self.rec.key_downs++;
	}
	else
	{
		self.rec.key_ups++;
	}
	self.rec.last_key = event.key;
	self.rec.watched_at_key = elem.ui.input.key_down(self.watch);
	return self.rec.consume_key;
}

fn void EventProbe.update(&self, Element* elem, float dt) @dynamic
{
	self.rec.updates++;
}

// ---------------------------------------------------------------------------
// CursorProbe: asks for a shape on the way in and closes its hand on a press,
// the way a drag handle does — the two hooks a cursor is set from. Counts its
// layouts so a test can show what changing the shape did NOT cost.

struct CursorProbe (Widget)
{
	Vec2 pref;
	Cursor shape;
	int* layouts;
}

fn void CursorProbe.on_hover(&self, Element* elem, bool entered) @dynamic
{
	if (entered) elem.set_cursor(self.shape);
}

fn Vec2 CursorProbe.layout(&self, Element* elem, Constraints c) @dynamic
{
	if (self.layouts) (*self.layouts)++;
	return c.constrain(self.pref);
}

fn bool CursorProbe.on_mouse(&self, Element* elem, MouseEvent event) @dynamic
{
	if (event.kind == MouseEventKind.PRESS) elem.set_cursor(Cursor.CLOSED_HAND);
	return true;
}

// ---------------------------------------------------------------------------
// MountProbe: records what mount() saw. `parent_at_mount` and `inherited`
// answer whether the tree was already wired when the hook ran; `mounts` counts
// the calls, which must stay at one however many relayouts happen.

struct MountRecord
{
	int mounts;
	int depth_at_mount; // hops to the root: 0 would mean the chain was not wired
	int layouts_at_mount; // the element's own layout count when mount ran
	Vec2 size_at_mount; // still zero: mount runs before the element is sized
}

struct MountProbe (Widget)
{
	Vec2 pref;
	MountRecord* rec;
	int layouts;
}

fn void MountProbe.mount(&self, Element* elem) @dynamic
{
	self.rec.mounts++;
	self.rec.size_at_mount = elem.size;
	self.rec.layouts_at_mount = self.layouts;
	for (Element* e = elem.parent; e != null; e = e.parent) self.rec.depth_at_mount++;
	elem.set_cursor(Cursor.CROSSHAIR);
}

fn Vec2 MountProbe.layout(&self, Element* elem, Constraints c) @dynamic
{
	self.layouts++;
	return c.constrain(self.pref);
}

// ---------------------------------------------------------------------------
// WatchProbe: reads a provided Steering through `Element.watch` from layout,
// paint, both or neither, and counts the calls — so a test can invalidate the
// value and see which hooks re-ran. The `reads_*` flags are what a branch that
// stops reading looks like from outside.

struct Steering
{
	float angle;
}

struct WatchProbe (Widget)
{
	Vec2 pref;
	int* layouts;
	int* paints;
	bool reads_in_layout;
	bool reads_in_paint;
	float* seen; // the angle the last watching paint read
}

fn Vec2 WatchProbe.layout(&self, Element* elem, Constraints c) @dynamic
{
	if (self.layouts) (*self.layouts)++;
	if (self.reads_in_layout) elem.watch(Steering)!!;
	return c.constrain(self.pref);
}

fn void WatchProbe.paint(&self, Element* elem, Painter* painter) @dynamic
{
	if (self.paints) (*self.paints)++;
	if (!self.reads_in_paint) return;
	Steering* steering = elem.watch(Steering)!!;
	if (self.seen) *self.seen = steering.angle;
}

// ---------------------------------------------------------------------------
// UnmountProbe: counts unmount() calls — proves release fired the hook.

struct UnmountProbe (Widget)
{
	int* count;
}

fn void UnmountProbe.unmount(&self, Element* elem) @dynamic
{
	if (self.count) (*self.count)++;
}
