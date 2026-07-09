module cui;
import std::collections::list;
import std::math;

// Input: the interactivity layer. Windowing-agnostic — the embedder (the
// cui::vulkan reference renderer, or an engine) fills an InputFrame each
// frame and calls Ui.process_input, which:
//
//   1. updates Ui.input — the queryable per-frame state ("context") any
//      widget can reach through elem.ui.input,
//   2. hit-tests the element tree and dispatches events to the optional
//      Widget callbacks (on_mouse / on_hover / on_key) with bubbling,
//   3. runs the optional per-frame update(dt) hook on every widget that
//      implements it.
//
// Widgets react by mutating their state and calling elem.request_paint()
// (or request_layout) — the usual invalidation path does the rest.

// ---------------------------------------------------------------------------
// Event types

enum MouseButton {
    LEFT,
    RIGHT,
    MIDDLE,
}

enum MouseEventKind {
    PRESS,
    RELEASE,
    MOVE,
    SCROLL,
}

struct MouseEvent {
    MouseEventKind kind;
    MouseButton button;     // which button, for PRESS/RELEASE
    Vec2 pos;               // element-local position
    Vec2 absolute;          // position in UI coordinates
    float scroll;           // wheel delta, for SCROLL (positive = up)
}

struct KeyEvent {
    Key key;
    bool down;              // true = pressed, false = released
}

// Mouse cursor shape, resolved per frame from the hovered element chain: the
// deepest hovered element whose `cursor` field is not DEFAULT wins (widgets
// like MouseRegion set it declaratively). The embedder applies Ui.cursor to
// the OS after process_input.
enum Cursor {
    DEFAULT,        // no preference — inherit from an ancestor, or ARROW
    ARROW,
    POINTING_HAND,
    IBEAM,
    CROSSHAIR,
    OPEN_HAND,
    CLOSED_HAND,
    RESIZE_H,
    RESIZE_V,
}

// Key identifiers. Values are X11 keycodes, matching c3w's EventKey.code so
// the reference renderer maps with `(Key)event_key.code`; engines with other
// key spaces translate to these constants.
constdef Key : inline uint
{
    EMPTY = 0,
    A = 38, B = 56, C = 54, D = 40, E = 26, F = 41, G = 42, H = 43,
    I = 31, J = 44, K = 45, L = 46, M = 58, N = 57, O = 32, P = 33,
    Q = 24, R = 27, S = 39, T = 28, U = 30, V = 55, W = 25, X = 53,
    Y = 29, Z = 52,
    KEY_0 = 19, KEY_1 = 10, KEY_2 = 11, KEY_3 = 12, KEY_4 = 13,
    KEY_5 = 14, KEY_6 = 15, KEY_7 = 16, KEY_8 = 17, KEY_9 = 18,
    ESCAPE = 9, RETURN = 36, SPACE = 65, DELETE = 119, TAB = 23,
    BACKSPACE = 22, INSERT = 118, CAPS_LOCK = 66,
    LEFT_SHIFT = 50, RIGHT_SHIFT = 62, LEFT_CTRL = 37, RIGHT_CTRL = 105,
    LEFT_ALT = 64, RIGHT_ALT = 108, LEFT_SUPER = 133, RIGHT_SUPER = 134,
    MENU = 135,
    LEFT_ARROW = 113, RIGHT_ARROW = 114, UP_ARROW = 111, DOWN_ARROW = 116,
    NUMLOCK = 77,
    NUM_0 = 90, NUM_1 = 87, NUM_2 = 88, NUM_3 = 89, NUM_4 = 83,
    NUM_5 = 84, NUM_6 = 85, NUM_7 = 79, NUM_8 = 80, NUM_9 = 81,
    KP_RETURN = 104, KP_ADD = 86, KP_SUBTRACT = 82, KP_MULTIPLY = 63,
    KP_DIVIDE = 106, KP_DECIMAL = 91,
    F1 = 67, F2 = 68, F3 = 69, F4 = 70, F5 = 71, F6 = 72, F7 = 73,
    F8 = 74, F9 = 75, F10 = 76, F11 = 95, F12 = 96, F13 = 97, F14 = 98,
    F15 = 99, F16 = 100, F17 = 101, F18 = 102, F19 = 103, F20 = 104,
    HOME = 110, END = 115, PAGE_UP = 112, PAGE_DOWN = 117,
    MINUS = 20, EQUALS = 21, LEFT_BRACKET = 34, RIGHT_BRACKET = 35,
    BACKSLASH = 51, SEMICOLON = 47, APOSTROPHE = 48, GRAVE = 49,
    COMMA = 59, PERIOD = 60, SLASH = 61,
    SCROLL_LOCK = 78, PAUSE = 127, PRINT_SCREEN = 107,
}

// ---------------------------------------------------------------------------
// Per-frame state, and what the embedder feeds in

// Lives on Ui as `ui.input` — readable from any widget via elem.ui. Note that
// paint() output is cached: widgets reading this from paint() won't see it
// change; react in the event callbacks or update(), then request_paint().
struct Input {
    Vec2 mouse;             // UI coordinates (top-left origin, pixels)
    Vec2 mouse_delta;
    bool[3] down;           // level state, indexed by MouseButton.ordinal
    bool[3] pressed;        // edge: went down this frame
    bool[3] released;       // edge: went up this frame
    float scroll;           // wheel delta this frame
    String text;            // UTF-8 typed this frame (borrowed from embedder)
    float time;             // seconds since the Ui started processing input
    float dt;
    Key[] keys_down;        // all currently held keys (borrowed, this frame)
}

fn bool Input.key_down(&self, Key key)
{
    foreach (k : self.keys_down) if (k == key) return true;
    return false;
}

// Everything the embedder knows about input this frame, in UI coordinates.
struct InputFrame {
    Vec2 mouse;
    bool[3] buttons;        // level state per MouseButton
    float scroll;
    String text;
    Key[] keys_down;
}

// ---------------------------------------------------------------------------
// Dispatch

// Call once per frame, before mutating the tree and before Ui.flush. Handlers
// may unmount elements from their own subtree; don't structurally modify
// unrelated parts of the tree from inside a handler.
fn void Ui.process_input(&self, InputFrame frame, float dt)
{
    Input* input = &self.input;

    input.dt = dt;
    input.time += dt;
    input.mouse_delta = frame.mouse - input.mouse;
    input.mouse = frame.mouse;
    input.scroll = frame.scroll;
    input.text = frame.text;
    for (sz b = 0; b < 3; b++) {
        input.pressed[b] = frame.buttons[b] && !input.down[b];
        input.released[b] = !frame.buttons[b] && input.down[b];
        input.down[b] = frame.buttons[b];
    }

    // Hover: the deepest element under the mouse; enter/leave on change.
    Element* hit = self.hit_test(input.mouse);
    if (hit != self.hovered) {
        Element* old = self.hovered;
        self.hovered = hit;
        if (old && &old.widget.on_hover) old.widget.on_hover(old, false);
        if (hit && &hit.widget.on_hover) hit.widget.on_hover(hit, true);
    }

    // Effective cursor: deepest hovered element with a preference wins.
    self.cursor = Cursor.ARROW;
    for (Element* e = self.hovered; e != null; e = e.parent) {
        if (e.cursor != Cursor.DEFAULT) {
            self.cursor = e.cursor;
            break;
        }
    }

    // While a press is being held by a consumer, everything routes to it —
    // drags keep working when the pointer leaves the element.
    Element* target = self.captured ? self.captured : hit;

    if (input.scroll != 0 && target) {
        self.dispatch_mouse(target, { .kind = SCROLL, .absolute = input.mouse, .scroll = input.scroll });
    }

    for (sz b = 0; b < 3; b++) {
        MouseButton button = MouseButton::from_ordinal(b);
        if (input.pressed[b]) {
            if (button == MouseButton.LEFT) self.update_focus(hit);
            Element* consumer = self.dispatch_mouse(target, { .kind = PRESS, .button = button, .absolute = input.mouse });
            if (consumer && !self.captured) {
                self.captured = consumer;
                self.capture_button = button;
            }
        }
        if (input.released[b]) {
            self.dispatch_mouse(target, { .kind = RELEASE, .button = button, .absolute = input.mouse });
            if (self.captured && button == self.capture_button) self.captured = null;
        }
    }

    if ((input.mouse_delta.x != 0 || input.mouse_delta.y != 0) && target) {
        self.dispatch_mouse(target, { .kind = MOVE, .absolute = input.mouse });
    }

    // Key edges: diff the held-key set against last frame, deliver to the
    // focused element (bubbling up from it).
    foreach (key : frame.keys_down) {
        if (!key_in(self.held_keys.array_view(), key)) self.dispatch_key({ .key = key, .down = true });
    }
    foreach (key : self.held_keys) {
        if (!key_in(frame.keys_down, key)) self.dispatch_key({ .key = key, .down = false });
    }
    self.held_keys.clear();
    foreach (key : frame.keys_down) self.held_keys.push(key);
    input.keys_down = self.held_keys.array_view();

    // Per-frame tick for widgets implementing update().
    if (self.root) self.tick(self.root, dt);
}

// Bubbles the event from `element` toward the root; each widget gets the
// position translated into its own local space. Returns the consumer.
fn Element* Ui.dispatch_mouse(&self, Element* element, MouseEvent event)
{
    for (Element* e = element; e != null; e = e.parent) {
        if (&e.widget.on_mouse) {
            event.pos = event.absolute - e.absolute;
            if (e.widget.on_mouse(e, event)) return e;
        }
    }
    return null;
}

fn void Ui.dispatch_key(&self, KeyEvent event)
{
    for (Element* e = self.focused; e != null; e = e.parent) {
        if (&e.widget.on_key) {
            if (e.widget.on_key(e, event)) return;
        }
    }
}

// Deepest element whose rect contains the point, in reverse paint order so
// visually-topmost wins. Uses the absolute origins stored by the last emit;
// transform-palette matrices (set_transform) are NOT applied to hit tests.
fn Element* Ui.hit_test(&self, Vec2 point)
{
    if (self.root == null) return null;
    return self.hit_test_element(self.root, point);
}

fn Element* Ui.hit_test_element(&self, Element* element, Vec2 point)
{
    foreach_r (child : element.children) {
        Element* hit = self.hit_test_element(child, point);
        if (hit) return hit;
    }
    Vec2 local = point - element.absolute;
    if (local.x >= 0 && local.y >= 0 && local.x < element.size.x && local.y < element.size.y) {
        return element;
    }
    return null;
}

// A left press focuses the deepest hit element that can receive key events.
fn void Ui.update_focus(&self, Element* hit)
{
    for (Element* e = hit; e != null; e = e.parent) {
        if (&e.widget.on_key) {
            self.focused = e;
            return;
        }
    }
    self.focused = null;
}

fn void Ui.tick(&self, Element* element, float dt)
{
    if (&element.widget.update) element.widget.update(element, dt);
    foreach (child : element.children) self.tick(child, dt);
}

fn bool key_in(Key[] keys, Key key)
{
    foreach (k : keys) if (k == key) return true;
    return false;
}
