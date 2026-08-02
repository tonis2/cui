<*
 Dialogs: a titled panel floating over the interface, dragged by its bar and
 dismissed from its own close button — an about box, a preferences sheet, a key
 reference.

 It escapes its parent's rect the same way a dropdown does: hit testing recurses
 into children without clipping to the parent, so the panel is simply a child
 bigger than the element holding it (see menu.c3). What a dialog adds over a
 PopupPanel is the chrome and the behaviour a window has and a menu does not —
 a bar to move it by, a close button, ESC, and the option of blocking everything
 behind it.

 The content is a builder rather than children: `Dialog.body` is the
 `ViewBuilder` shape `AreaView` takes, called each time the dialog opens. The
 subtree it returns is released wholesale on close, so anything the content must
 remember across a close belongs on the app (reached with `ui.inherit`) — the
 composite rule from build.md.

 Data is borrowed like everywhere else here: the title string and the style must
 outlive the widget.
*>
module cui::widgets;
import std::math;

import cui;

<*
 One look for a dialog. Pass a complete style or none at all: a zero
 `title_height` means "use DEFAULT_DIALOG_STYLE wholesale", and a partially
 filled style is not merged field-by-field — the MenuStyle convention.
*>
struct DialogStyle
{
	Color panel_color;
	Color panel_border;
	Color title_color; // the bar across the top
	Color text_color; // the title, and the close glyph under the pointer
	Color dim_color; // the close glyph at rest
	Color hover_color; // behind the hovered close button
	Color scrim_color; // what a modal dialog dims the rest of the window with
	FontId font; // 0 = the first loaded font
	float text_size;
	float title_height; // 0 = the whole style defaults
	float pad_x; // inset from the panel's side edges, in the bar and around the body
	float pad_y; // inset above and below the body
	float radius; // corner radius of the panel
	float shadow; // drop shadow blur in px; 0 = no shadow
	float min_width; // least width the panel takes, however narrow its content
}

const DialogStyle DEFAULT_DIALOG_STYLE = {
	.panel_color = { 0.16, 0.17, 0.22, 1.0 },
	.panel_border = { 0.28, 0.30, 0.38, 1.0 },
	.title_color = { 0.13, 0.14, 0.18, 1.0 },
	.text_color = { 0.92, 0.93, 0.95, 1.0 },
	.dim_color = { 0.55, 0.58, 0.66, 1.0 },
	.hover_color = { 0.28, 0.31, 0.40, 1.0 },
	.scrim_color = { 0.0, 0.0, 0.0, 0.45 },
	.text_size = 14.0,
	.title_height = 30.0,
	.pad_x = 14.0,
	.pad_y = 12.0,
	.radius = 8.0,
	.shadow = 18.0,
	.min_width = 220.0,
};

fn DialogStyle DialogStyle.resolved(self)
{
	return self.title_height > 0 ? self : DEFAULT_DIALOG_STYLE;
}

// The close button is square and this is its side, in pixels. Not in the style:
// it is sized against the title bar it sits in, not against the app's taste.
const float DIALOG_CLOSE_SIZE = 18.0;

// How much of its screen a dialog leaves free around itself. A panel wider than
// what is left is offered exactly that and clipped by nothing — its content
// decides what to do with too little room.
const float DIALOG_MARGIN = 24.0;

const Color DIALOG_SHADOW_COLOR = { 0.0, 0.0, 0.0, 0.45 };

<*
 The id stamped on the close button, so a test or a script can press it:
 `ui.find_id(DIALOG_CLOSE_ID)`. Shared by every dialog in the tree — with more
 than one open, reach them with `@each_id`.
*>
const String DIALOG_CLOSE_ID = "dialog-close";

<*
 A floating titled panel.

 Mount one wherever it should sit in the paint order — later siblings still
 paint over it, so a dialog built before an app's menu bar keeps that bar's
 dropdowns on top — and toggle it with `set_open` / `toggle`. Closed it is a
 zero-size element that paints nothing and cannot be hit, so a dialog can live
 in the tree from startup and cost a layout call per frame it changes.

 Placement: centred on its screen (`Element.media`, so a dialog inside a split
 pane centres on the pane) until it is dragged, then wherever it was left,
 always clamped to stay on that screen. Because the panel is placed against the
 element's `absolute` — the previous emit's value — a dialog whose own element
 moves lags one frame behind it; mount it somewhere that does not move, as
 popups here already are.

 Modal (`modal`) makes the element itself the backdrop: it covers what it
 blocks, dims it with `scrim_color`, and swallows the presses that land on it.
 Non-modal, the rest of the window stays live and the dialog is just on top.

 Keys: ESC closes an open dialog. Focus moves here when it opens, which is what
 puts ESC in reach; every other key is declined and bubbles to whatever the app
 keeps its shortcuts on, so a dialog does not take the keyboard hostage.

 Note for anyone adding state: this widget implements `paint`, so
 `request_paint` does NOT route to `request_build` on it (see
 `Element.request_paint`). Anything that changes what the dialog *contains* has
 to request a build — `set_open` does.
*>
struct Dialog (Widget)
{
	String title; // borrowed; must outlive the widget
	ViewBuilder body; // builds the content; called on every open
	DialogStyle style;
	bool open;
	bool modal; // dim and block everything behind it
	bool close_outside; // modal only: a press on the backdrop closes the dialog
	OnClick on_close; // optional; called whenever the dialog goes from open to closed
	Vec2 at; // the panel's top-left in UI coordinates; written by layout
	bool placed; // false = centre it (and re-centre it on every layout)
}

<*
 Builds the panel — the bar with its close button over the content — or nothing
 at all while closed.

 @param elem : `The element this widget is attached to.`
 @require self.body != null : `A Dialog needs a body builder — the panel is chrome around content.`
 @return `The panel subtree, or a childless Stack that layout sizes to zero.`
*>
fn Element* Dialog.build(&self, Element* elem) @dynamic
{
	Ui* ui = elem.ui;

	// A composite builds exactly one node, and this is the cheapest node that
	// paints nothing and cannot be hit once `layout` has sized it to zero.
	if (!self.open) return ui.@node((Stack) { });

	DialogStyle s = self.style.resolved();

	// The bar's own needs, folded into the panel's minimum here rather than in
	// the frame: this is where the title is, and the frame's job is to negotiate
	// one width out of the numbers it is handed.
	float head = 2 * s.pad_x + ui.text.measure(s.font, self.title, s.text_size).x
		+ s.pad_x + DIALOG_CLOSE_SIZE;

	Element* close = ui.@node((DialogCloseButton) { .style = s, .host = elem })
		.with_id(DIALOG_CLOSE_ID);
	Element* bar = ui.@node((DialogTitleBar) { .title = self.title, .style = s, .host = elem }, close);
	return ui.@node((DialogFrame) { .style = s, .min_width = math::max(s.min_width, head) },
		bar, self.body(ui));
}

<*
 Sizes and places the panel, and the element itself to what it has to block:
 everything offered while modal, nothing at all otherwise.

 @param elem : `The element this widget is attached to.`
 @param constraints : `The size range offered by the parent.`
 @require elem.children.len() == 1 : `A composite is laid out with exactly the subtree it built.`
 @return `The backdrop's size while modal; zero while not.`
*>
fn Vec2 Dialog.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	if (!self.open)
	{
		elem.layout_child(0, { .min = { 0, 0 }, .max = { 0, 0 } });
		return { 0, 0 };
	}

	Media screen = elem.media();
	Vec2 room = {
		math::max(screen.size.x - 2 * DIALOG_MARGIN, 0.0f),
		math::max(screen.size.y - 2 * DIALOG_MARGIN, 0.0f),
	};
	Vec2 panel = elem.layout_child(0, { .min = { 0, 0 }, .max = room });

	// Centred until someone drags it, and clamped onto the screen either way —
	// which is also what stops a drag from posting the panel off the edge.
	Vec2 wanted = self.placed ? self.at : (Vec2) {
		screen.origin.x + (screen.size.x - panel.x) * 0.5f,
		screen.origin.y + (screen.size.y - panel.y) * 0.5f,
	};
	self.at = screen.clamp_rect(wanted, panel);
	elem.place_child(0, self.at - elem.absolute);

	return self.modal ? constraints.max : (Vec2) { 0, 0 };
}

<*
 The modal backdrop, and nothing else — the panel is a child and paints itself.

 @param elem : `The element this widget is attached to.`
 @param painter : `The painter to draw into, in element-local coordinates.`
*>
fn void Dialog.paint(&self, Element* elem, Painter* painter) @dynamic
{
	if (!self.open || !self.modal) return;
	painter.rect({ 0, 0 }, elem.size, { .color = self.style.resolved().scrim_color });
}

<*
 The blocking half of being modal: a press, release or wheel that got this far
 landed on the backdrop, because the panel consumes its own. With
 `close_outside` set, that press is also the dismissal.
*>
fn bool Dialog.on_mouse(&self, Element* elem, MouseEvent event) @dynamic
{
	if (!self.open || !self.modal) return false;
	if (event.kind == MouseEventKind.MOVE) return false;
	if (event.kind == MouseEventKind.PRESS && self.close_outside) self.set_open(elem, false);
	return true;
}

fn bool Dialog.on_key(&self, Element* elem, KeyEvent event) @dynamic
{
	if (!self.open || !event.down || event.key != Key.ESCAPE) return false;
	self.set_open(elem, false);
	return true;
}

<*
 Shows or dismisses the dialog. A no-op when it is already in that state, so a
 menu item polling this to draw a check mark cannot make it flicker.

 Opening focuses the dialog — that is what puts ESC in reach — and closing runs
 `on_close`, whoever asked for the close: the button, ESC, the backdrop, or the
 app calling this directly.

 @param elem : `The Dialog's own element.`
 @param open : `True to show it, false to dismiss it.`
*>
fn void Dialog.set_open(&self, Element* elem, bool open)
{
	if (self.open == open) return;
	self.open = open;
	if (open) elem.request_focus();
	if (!open && self.on_close) self.on_close(elem.ui);

	// A build, not a paint: this widget paints (the backdrop), so `request_paint`
	// would stop at the backdrop and leave the panel exactly as it was.
	elem.request_build();
}

<*
 The other way round from wherever it is now — what a View > Something menu item
 wants.

 @param elem : `The Dialog's own element.`
*>
fn void Dialog.toggle(&self, Element* elem) => self.set_open(elem, !self.open);

// ---------------------------------------------------------------------------

<*
 The panel: background, border, shadow, and the title bar stacked over the body.
 Internal — Dialog builds it.

 A widget of its own rather than a PopupPanel wrapping a Column, because the
 width is negotiated in both directions: the body is measured first, the bar is
 then stretched to whatever the body needs, and both are floored by the minimum
 the bar's own title and button need. A Column would leave the bar wrapping its
 text in the middle of a wide panel.

 It consumes clicks on its chrome for the reason PopupPanel does, with a sharper
 edge here: a press that fell through the panel would reach the modal backdrop
 underneath and dismiss the dialog the user was aiming at.
*>
struct DialogFrame (Widget)
{
	DialogStyle style; // resolved by the Dialog that built it
	float min_width; // the style's minimum, or what the title bar needs
}

<*
 Measures the body, settles the width, and stacks the two children.

 @param elem : `The element this widget is attached to.`
 @param constraints : `The size range offered by the parent.`
 @require elem.children.len() == 2 : `A DialogFrame is built with exactly two children: the title bar and the body.`
 @return `The panel's size: the settled width by bar + body + insets.`
*>
fn Vec2 DialogFrame.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	DialogStyle s = self.style;
	Vec2 inner = {
		math::max(constraints.max.x - 2 * s.pad_x, 0.0f),
		math::max(constraints.max.y - s.title_height - 2 * s.pad_y, 0.0f),
	};
	Vec2 body = elem.layout_child(1, { .min = { 0, 0 }, .max = inner });

	float width = math::min(math::max(body.x + 2 * s.pad_x, self.min_width), constraints.max.x);
	Vec2 bar = { width, s.title_height };
	elem.layout_child(0, { .min = bar, .max = bar });
	elem.place_child(0, { 0, 0 });
	elem.place_child(1, { s.pad_x, s.title_height + s.pad_y });

	return { width, s.title_height + body.y + 2 * s.pad_y };
}

fn void DialogFrame.paint(&self, Element* elem, Painter* painter) @dynamic
{
	DialogStyle s = self.style;
	Vec4 radii = { s.radius, s.radius, s.radius, s.radius };
	if (s.shadow > 0)
	{
		painter.rect_shadow({ 0, 0 }, elem.size, s.shadow, DIALOG_SHADOW_COLOR, radii);
	}
	painter.rect({ 0, 0 }, elem.size, {
		.color = s.panel_color,
		.border_width = 1.0,
		.border_color = s.panel_border,
		.border_radius = radii,
	});
}

fn bool DialogFrame.on_mouse(&self, Element* elem, MouseEvent event) @dynamic
{
	return event.kind == MouseEventKind.PRESS || event.kind == MouseEventKind.RELEASE;
}

// ---------------------------------------------------------------------------

<*
 The bar across the top: the title, the close button in it, and the grip the
 whole dialog moves by. Internal.

 A drag writes the position onto the Dialog rather than onto this element. The
 position belongs to the dialog — it is what the panel is clamped and re-placed
 from, and it has to survive the rebuild that this bar does not.
*>
struct DialogTitleBar (Widget)
{
	String title;
	DialogStyle style; // resolved by the Dialog that built it
	Element* host; // the Dialog element
	bool dragging;
	Vec2 grab; // where inside the panel the pointer took hold
}

<*
 Fills the width the frame gives it and puts the close button at the right end.

 @param elem : `The element this widget is attached to.`
 @param constraints : `The size range offered by the parent.`
 @require elem.children.len() == 1 : `A DialogTitleBar is built with exactly one child: the close button.`
 @return `The bar's size: the offered width by the style's title height.`
*>
fn Vec2 DialogTitleBar.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	elem.cursor = self.dragging ? Cursor.CLOSED_HAND : Cursor.OPEN_HAND;
	Vec2 own = cui::clamp_size({ constraints.max.x, self.style.title_height }, constraints);

	Vec2 close = { DIALOG_CLOSE_SIZE, DIALOG_CLOSE_SIZE };
	elem.layout_child(0, { .min = close, .max = close });
	elem.place_child(0, { own.x - self.style.pad_x - close.x, (own.y - close.y) * 0.5f });
	return own;
}

fn void DialogTitleBar.paint(&self, Element* elem, Painter* painter) @dynamic
{
	DialogStyle s = self.style;

	// Rounded at the top and square at the bottom: the bar is the top of the
	// panel, not a card sitting on it.
	painter.rect({ 0, 0 }, elem.size, {
		.color = s.title_color,
		.border_radius = { s.radius, s.radius, 0.0, 0.0 },
	});
	painter.rect({ 0, elem.size.y - 1 }, { elem.size.x, 1 }, { .color = s.panel_border });

	Vec2 text = elem.ui.text.measure(s.font, self.title, s.text_size);
	painter.text({ s.pad_x, (elem.size.y - text.y) * 0.5f }, self.title, {
		.font = s.font, .size = s.text_size, .color = s.text_color,
	});
}

<*
 Moves the dialog. Consuming the press captures the pointer, so the drag keeps
 up when it outruns the bar; the panel follows the pointer by the offset it was
 grabbed at, which is what stops its corner from jumping under the cursor.
*>
fn bool DialogTitleBar.on_mouse(&self, Element* elem, MouseEvent event) @dynamic
{
	switch (event.kind)
	{
		case PRESS:
			if (event.button != MouseButton.LEFT) return false;
			self.dragging = true;
			self.grab = event.absolute - self.host.widget_as(Dialog).at;
			elem.request_layout(); // the cursor is declared there
			return true;
		case RELEASE:
			if (event.button != MouseButton.LEFT || !self.dragging) return false;
			self.dragging = false;
			elem.request_layout();
			return true;
		case MOVE:
			if (!self.dragging) return false;
			Dialog* dialog = self.host.widget_as(Dialog);
			dialog.at = event.absolute - self.grab;
			dialog.placed = true;
			self.host.request_layout(); // which clamps it back onto the screen
			return true;
		default:
			return false;
	}
}

// ---------------------------------------------------------------------------

<*
 The × at the right end of the title bar. Internal.
*>
struct DialogCloseButton (Widget)
{
	DialogStyle style; // resolved by the Dialog that built it
	Element* host; // the Dialog element
	bool hovered;
}

fn Vec2 DialogCloseButton.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	elem.cursor = Cursor.POINTING_HAND;
	return cui::clamp_size({ DIALOG_CLOSE_SIZE, DIALOG_CLOSE_SIZE }, constraints);
}

fn void DialogCloseButton.paint(&self, Element* elem, Painter* painter) @dynamic
{
	DialogStyle s = self.style;
	if (self.hovered)
	{
		float r = elem.size.x * 0.5f;
		painter.rect({ 0, 0 }, elem.size, { .color = s.hover_color, .border_radius = { r, r, r, r } });
	}

	// The glyph is inset from the button's own edge, so the hover disc reads as a
	// target around the × rather than a box behind it.
	float pad = elem.size.x * 0.3f;
	Color ink = self.hovered ? s.text_color : s.dim_color;
	painter.line({ pad, pad }, { elem.size.x - pad, elem.size.y - pad }, 1.4f, ink);
	painter.line({ elem.size.x - pad, pad }, { pad, elem.size.y - pad }, 1.4f, ink);
}

fn void DialogCloseButton.on_hover(&self, Element* elem, bool entered) @dynamic
{
	self.hovered = entered;
	elem.request_paint();
}

fn bool DialogCloseButton.on_mouse(&self, Element* elem, MouseEvent event) @dynamic
{
	switch (event.kind)
	{
		case PRESS:
			return event.button == MouseButton.LEFT;
		case RELEASE:
			if (event.button != MouseButton.LEFT) return false;
			bool inside = event.pos.x >= 0 && event.pos.y >= 0
				&& event.pos.x < elem.size.x && event.pos.y < elem.size.y;

			// Closing releases this element's whole subtree — deferred to the build
			// pass by `request_build`, which is what makes it safe from in here.
			if (inside) self.host.widget_as(Dialog).set_open(self.host, false);
			return true;
		default:
			return false;
	}
}
