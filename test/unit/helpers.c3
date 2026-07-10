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
fn void frame(Ui* ui, Vec2 mouse, bool left = false, float scroll = 0, Key[] keys = {})
{
	ui.process_input({
		.mouse = mouse,
		.buttons = { left, false, false },
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
	return cui::clamp_size(self.pref, c);
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
	bool consume_mouse;
	bool consume_key;
}

struct EventProbe (Widget)
{
	Vec2 pref;
	EventRecord* rec;
}

fn Vec2 EventProbe.layout(&self, Element* elem, Constraints c) @dynamic
{
	Vec2 size = cui::clamp_size(self.pref, c);
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
	return self.rec.consume_key;
}

fn void EventProbe.update(&self, Element* elem, float dt) @dynamic
{
	self.rec.updates++;
}

// ---------------------------------------------------------------------------
// UnmountProbe: counts unmount() calls — proves release fired the hook.

struct UnmountProbe (Widget)
{
	int* count;
}

fn void UnmountProbe.unmount(&self) @dynamic
{
	if (self.count) (*self.count)++;
}
