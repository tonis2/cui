<*
 Menus: an application menu bar with dropdowns, a standalone dropdown selector,
 and the popup panel they both draw their lists on.

 Everything here is composed from the Widget interface like any app widget —
 nothing in the core knows what a menu is. The one mechanism worth naming is how
 a dropdown escapes its parent's rect: hit testing recurses into children
 without clipping to the parent (see Ui.hit_test_element), so an open menu's
 subtree simply contains elements bigger than the bar — the panel below it, and
 a window-sized catcher that turns any click elsewhere into "close". No overlay
 layer, no second tree.

 Data (Menu, MenuItem) is borrowed, like Label.text: the arrays must outlive the
 widget, and module-level constants are the intended shape.
*>
module cui::widgets;
import std::math;

import cui;

<*
 One look shared by MenuBar and Select. Pass a complete style or none at all: a
 zero `bar_height` means "use DEFAULT_MENU_STYLE wholesale", and a partially
 filled style is not merged field-by-field.
*>
struct MenuStyle
{
	Color bar_color; // menu bar background
	Color bar_border; // the 1px line under the bar
	Color panel_color; // dropdown background
	Color panel_border;
	Color hover_color; // behind the hovered title, item or option
	Color open_color; // behind the title whose menu is open
	Color text_color;
	Color dim_color; // shortcuts and disabled items
	FontId font; // 0 = the first loaded font
	float text_size;
	float bar_height; // 0 = the whole style defaults
	float item_height;
	float pad_x; // horizontal padding inside titles and items
}

const MenuStyle DEFAULT_MENU_STYLE = {
	.bar_color = { 0.13, 0.14, 0.18, 1.0 },
	.bar_border = { 0.28, 0.30, 0.38, 1.0 },
	.panel_color = { 0.16, 0.17, 0.22, 1.0 },
	.panel_border = { 0.28, 0.30, 0.38, 1.0 },
	.hover_color = { 0.28, 0.31, 0.40, 1.0 },
	.open_color = { 0.22, 0.24, 0.31, 1.0 },
	.text_color = { 0.92, 0.93, 0.95, 1.0 },
	.dim_color = { 0.55, 0.58, 0.66, 1.0 },
	.text_size = 14.0,
	.bar_height = 28.0,
	.item_height = 26.0,
	.pad_x = 12.0,
};

// Left gutter inside an item row where the check mark lives; labels start after
// it, so checked and unchecked items line up.
const float CHECK_GUTTER = 24.0;

// Least width a dropdown panel takes, however short its labels — a two-item
// menu the width of "Cut" reads as a glitch, not a menu.
const float PANEL_MIN_W = 168.0;

const float SEPARATOR_H = 9.0;
const float PANEL_PAD_Y = 5.0;
const float POPUP_SHADOW = 14.0;

fn MenuStyle MenuStyle.resolved(self)
{
	return self.bar_height > 0 ? self : DEFAULT_MENU_STYLE;
}

<*
 The live state of a dropdown entry, polled through MenuItem.state whenever the
 dropdown is (re)built — so a check mark set by a keyboard shortcut is already
 right the next time the menu opens, without anyone pushing updates into menu
 data.
*>
bitstruct MenuItemFlags : char
{
	bool checked;
	bool disabled;
}

<*
 Polled state for one item, called when its dropdown is built. Reach the app
 through `ui.inherit`, the same way OnClick handlers do.
*>
alias MenuQuery = fn MenuItemFlags(Ui* ui);

<*
 A selection callback for Select: which option was chosen.
*>
alias OnSelect = fn void(Ui* ui, usz index);

<*
 One dropdown entry. `on_select` receives the Ui, like Button.on_click — the
 handler reaches the app through `ui.inherit`. When `state` is set it overrides
 the two bools each time the dropdown opens; without it they are read as-is.

 A `separator` entry is a divider and every other field is ignored.
*>
struct MenuItem
{
	String label; // borrowed; must outlive the widget
	String shortcut; // displayed right-aligned and dim; purely a reminder
	OnClick on_select;
	MenuQuery state;
	bool checked;
	bool disabled;
	bool separator;
}

<*
 One title on the bar and the items under it.
*>
struct Menu
{
	String title; // borrowed; must outlive the widget
	MenuItem[] items; // borrowed
}

// ---------------------------------------------------------------------------
// PopupPanel — the chrome under any floating list.

<*
 A floating panel: background, border, drop shadow, insets around one child,
 sized to that child. MenuBar and Select put their lists on one; a dialog or a
 tooltip would use the same widget.

 It consumes clicks on its own chrome (padding, separator gaps): a popup is
 above whatever is behind it, and a click that hits its background must not fall
 through to a close-catcher underneath and dismiss the popup mid-aim.
*>
struct PopupPanel (Widget)
{
	RectStyle style;
	Insets insets;
	float shadow; // blur in px; 0 = no shadow
	Color shadow_color;
}

fn Vec2 PopupPanel.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	// Deliberately unconstrained, like SelectCatcher below: a popup floats over
	// the layout rather than participating in it, and the anchor it hangs off —
	// a Select's head, a menu bar's strip — is usually far smaller than the
	// list. Clamping to the anchor's constraints is how a dropdown's rows end
	// up zero-height. The panel takes exactly content + insets, wherever it is.
	float w = self.insets.left + self.insets.right;
	float h = self.insets.top + self.insets.bottom;
	Vec2 child = { 0, 0 };
	if (elem.children.len() > 0)
	{
		child = elem.layout_child(0, cui::loose({ cui::UNBOUNDED, cui::UNBOUNDED }));
		elem.place_child(0, { self.insets.left, self.insets.top });
	}
	return { child.x + w, child.y + h };
}

fn void PopupPanel.paint(&self, Element* elem, Painter* painter) @dynamic
{
	if (self.shadow > 0)
	{
		painter.rect_shadow({ 0, 0 }, elem.size, self.shadow, self.shadow_color, self.style.border_radius);
	}
	painter.rect({ 0, 0 }, elem.size, self.style);
}

fn bool PopupPanel.on_mouse(&self, Element* elem, MouseEvent event) @dynamic
{
	return event.kind == MouseEventKind.PRESS || event.kind == MouseEventKind.RELEASE;
}

// ---------------------------------------------------------------------------
// MenuBar

<*
 An application menu bar: a row of titles, one dropdown open at a time.

 A composite. Closed, it builds just the row of titles; open, it builds a
 window-filling Stack holding the titles row and the dropdown panel — and that
 Stack is itself the click-catcher: a press anywhere that no title or item
 claims bubbles to MenuBar.on_mouse, which closes the menu and consumes the
 press. So while a menu is open the rest of the window is dead, exactly like a
 native menu, and the click that dismisses it does not also act on what it
 landed on. Titles stay live above the catcher, which is what makes clicking
 another title switch menus, and hovering one slide over, Blender-style.

 The element reports the BAR's size from layout — {available width, bar height}
 — never the built subtree's. The open-state subtree is window-sized, and an
 element that big would win every hit test everywhere even while closed.

 The dropdown is placed against the bar's screen (`Element.media`), not simply
 hung under its title: a bar inside a pane too short for the whole menu slides
 it up over itself rather than letting the last items fall off the pane's
 bottom edge, where a clipping pane would cut them off.

 Keys: ESC closes an open menu; everything else is declined so it bubbles past
 the bar to whatever the app keeps its shortcuts on.

 Ids for tests and tooling: every title and item element is stamped with its own
 title/label via with_id, so `ui.find_id("Undo")` resolves while its menu is
 open.
*>
struct MenuBar (Widget)
{
	Menu[] menus; // borrowed
	MenuStyle style;
	usz open; // 0 = closed, else 1-based index into menus

	// The press that opened the current dropdown, until its release arrives. A
	// dropdown with no room below the bar is placed over the bar (see
	// `Media.drop`), which can leave a row sitting exactly under that press —
	// and the release would then choose it, so the click that opened the menu
	// would pick from it in the same gesture. The position is kept because the
	// OTHER way to use a menu is press, drag onto an item, release: that one
	// still has to select, and what tells them apart is whether the pointer
	// moved.
	bool arming;
	Vec2 armed_at;
}

// How far the pointer may drift and the release still count as part of the
// click that opened the menu rather than a drag onto an item.
const float MENU_ARM_SLOP = 4.0;

fn Element* MenuBar.build(&self, Element* elem) @dynamic
{
	MenuStyle s = self.style.resolved();
	Ui* ui = elem.ui;

	if (self.open == 0 || self.open > self.menus.len)
	{
		return @subtree(ui)
		{
			build_title_row(ui, elem, self.menus, s);
		};
	}

	Menu menu = self.menus[self.open - 1];

	// The dropdown sits under its own title: accumulate the widths of the
	// titles before it, the same measure the titles size themselves with.
	float panel_x = 0;
	foreach (i, m : self.menus)
	{
		if ((usz)i + 1 == self.open) break;
		panel_x += ui.text.measure(s.font, m.title, s.text_size).x + 2 * s.pad_x;
	}

	// Uniform row width: the widest label + shortcut decides for the panel. The
	// height comes out of the same pass — the rows are laid out below, but where
	// the panel goes has to be decided before it is built.
	float row_w = PANEL_MIN_W;
	float panel_h = 2 * PANEL_PAD_Y;
	foreach (item : menu.items)
	{
		if (item.separator)
		{
			panel_h += SEPARATOR_H;
			continue;
		}
		panel_h += s.item_height;
		float w = CHECK_GUTTER + ui.text.measure(s.font, item.label, s.text_size).x + 2 * s.pad_x;
		if (item.shortcut.len > 0) w += ui.text.measure(s.font, item.shortcut, s.text_size).x + s.pad_x;
		row_w = math::max(row_w, w);
	}

	// Under its title, but on the screen the bar is on: in a pane short enough
	// that the whole menu will not fit below the bar, it slides up over the bar
	// rather than running off the bottom edge and being clipped there.
	Vec2 panel_at = elem.media().drop(
		{ elem.absolute.x + panel_x, elem.absolute.y },
		s.bar_height,
		{ row_w, panel_h },
	) - elem.absolute;

	return @subtree(ui)
	{
		@tree((Stack) { }) // fills the window: the click-catcher
		{
			build_title_row(ui, elem, self.menus, s);

			@tree((PopupPanel) {
				.style = {
					.color = s.panel_color,
					.border_width = 1.0,
					.border_color = s.panel_border,
					.border_radius = { 0.0, 0.0, 6.0, 6.0 },
				},
				.insets = { 0.0, PANEL_PAD_Y, 0.0, PANEL_PAD_Y },
				.shadow = POPUP_SHADOW,
				.shadow_color = { 0.0, 0.0, 0.0, 0.45 },
			})
			{
				@tree((Column) { })
				{
					foreach (item : menu.items)
					{
						if (item.separator)
						{
							@node((MenuSeparator) { .style = s, .size = { row_w, SEPARATOR_H } });
							continue;
						}
						MenuItem live = item;
						if (live.state)
						{
							MenuItemFlags flags = live.state(ui);
							live.checked = flags.checked;
							live.disabled = flags.disabled;
						}
						@node((MenuItemRow) { .item = live, .style = s, .width = row_w, .bar = elem })
							.with_id(live.label);
					}
				};
			}.set_offset(panel_at);
		};
	};
}

<*
 The titles row, shared by both build shapes so the bar looks identical open and
 closed.
*>
fn void build_title_row(Ui* ui, Element* bar, Menu[] menus, MenuStyle s) @private
{
	@tree((Row) { .size = { 0, s.bar_height } })
	{
		foreach (i, menu : menus)
		{
			@node((MenuTitle) { .title = menu.title, .style = s, .index = (usz)i + 1, .bar = bar })
				.with_id(menu.title);
		}
	};
}

fn Vec2 MenuBar.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	if (elem.children.len() > 0)
	{
		elem.layout_child(0, cui::loose(constraints.max));
		elem.place_child(0, { 0, 0 });
	}
	return constraints.constrain({ constraints.max.x, self.style.resolved().bar_height });
}

<*
 The bar strip itself — the built subtree draws everything else. Having a paint
 means request_paint no longer routes to request_build, so open/close always
 goes through request_build explicitly (the titles and items do).
*>
fn void MenuBar.paint(&self, Element* elem, Painter* painter) @dynamic
{
	MenuStyle s = self.style.resolved();
	painter.rect({ 0, 0 }, elem.size, { .color = s.bar_color });
	painter.rect({ 0, elem.size.y - 1 }, { elem.size.x, 1 }, { .color = s.bar_border });
}

<*
 Dismisses the open dropdown, if there is one. Safe to call when nothing is
 open, and safe from a handler inside the subtree it condemns.

 Public for the app that puts controls of its own on the bar: those sit *above*
 the bar in the tree, so their clicks never reach the catcher, and without this
 the dropdown would hang over the action they just ran.

 @param elem : `The bar's element — the one that rebuilds.`
*>
fn void MenuBar.close(&self, Element* elem)
{
	if (self.open == 0) return;
	self.open = 0;
	elem.request_build();
}

<*
 The close-on-click-elsewhere half of being a menu: any press that bubbles this
 far was on the open catcher (or the bare bar strip), so nothing more specific
 wanted it.
*>
fn bool MenuBar.on_mouse(&self, Element* elem, MouseEvent event) @dynamic
{
	if (event.kind != MouseEventKind.PRESS) return false;
	self.close(elem);
	return true;
}

fn bool MenuBar.on_key(&self, Element* elem, KeyEvent event) @dynamic
{
	if (self.open != 0 && event.down && event.key == Key.ESCAPE)
	{
		self.close(elem);
		return true;
	}
	return false;
}

<*
 One title on the bar. Internal — MenuBar builds these.

 Press toggles its own menu. Hover, while any menu is open, switches to this one
 without a click; the released element under the pointer is rebuilt, hover
 re-enters the fresh title, and the highlight carries over.
*>
struct MenuTitle (Widget)
{
	String title;
	MenuStyle style;
	usz index; // 1-based, matching MenuBar.open
	Element* bar; // the MenuBar element, to reach and rebuild it
	bool hovered;
}

fn Vec2 MenuTitle.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	Vec2 text = elem.ui.text.measure(self.style.font, self.title, self.style.text_size);
	return constraints.constrain({ text.x + 2 * self.style.pad_x, self.style.bar_height });
}

fn void MenuTitle.paint(&self, Element* elem, Painter* painter) @dynamic
{
	MenuStyle s = self.style;
	bool is_open = self.bar.widget_as(MenuBar).open == self.index;
	if (is_open || self.hovered)
	{
		painter.rect({ 1, 2 }, { elem.size.x - 2, elem.size.y - 4 }, {
			.color = is_open ? s.open_color : s.hover_color,
			.border_radius = { 4.0, 4.0, 4.0, 4.0 },
		});
	}
	Vec2 text = elem.ui.text.measure(s.font, self.title, s.text_size);
	painter.text({ s.pad_x, (elem.size.y - text.y) * 0.5f }, self.title, {
		.font = s.font, .size = s.text_size, .color = s.text_color,
	});
}

fn void MenuTitle.on_hover(&self, Element* elem, bool entered) @dynamic
{
	self.hovered = entered;
	if (entered) elem.set_cursor(Cursor.POINTING_HAND);
	MenuBar* bar = self.bar.widget_as(MenuBar);
	if (entered && bar.open != 0 && bar.open != self.index)
	{
		bar.open = self.index;
		self.bar.request_build();
		return; // this element is condemned; the rebuilt title repaints anyway
	}
	elem.request_paint();
}

fn bool MenuTitle.on_mouse(&self, Element* elem, MouseEvent event) @dynamic
{
	switch (event.kind)
	{
		case PRESS:
			if (event.button != MouseButton.LEFT) return false;
			MenuBar* bar = self.bar.widget_as(MenuBar);
			bool opening = bar.open != self.index;
			bar.open = opening ? self.index : 0;
			bar.arming = opening;
			bar.armed_at = event.absolute;
			self.bar.request_build();
			return true;
		case RELEASE:
			return event.button == MouseButton.LEFT;
		default:
			return false;
	}
}

<*
 One dropdown entry. Internal — MenuBar builds these with the polled flags
 already folded in.
*>
struct MenuItemRow (Widget)
{
	MenuItem item;
	MenuStyle style;
	float width;
	Element* bar;
	bool hovered;
}

fn Vec2 MenuItemRow.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	return constraints.constrain({ self.width, self.style.item_height });
}

fn void MenuItemRow.paint(&self, Element* elem, Painter* painter) @dynamic
{
	MenuStyle s = self.style;
	if (self.hovered && !self.item.disabled)
	{
		painter.rect({ 2, 0 }, { elem.size.x - 4, elem.size.y }, {
			.color = s.hover_color,
			.border_radius = { 4.0, 4.0, 4.0, 4.0 },
		});
	}

	Color ink = self.item.disabled ? s.dim_color : s.text_color;
	if (self.item.checked)
	{
		float h = elem.size.y;
		painter.line({ 8.0, h * 0.52f }, { 11.0, h * 0.68f }, 1.6f, ink);
		painter.line({ 11.0, h * 0.68f }, { 17.0, h * 0.32f }, 1.6f, ink);
	}

	Vec2 text = elem.ui.text.measure(s.font, self.item.label, s.text_size);
	float text_y = (elem.size.y - text.y) * 0.5f;
	painter.text({ CHECK_GUTTER, text_y }, self.item.label, {
		.font = s.font, .size = s.text_size, .color = ink,
	});

	if (self.item.shortcut.len > 0)
	{
		Vec2 hint = elem.ui.text.measure(s.font, self.item.shortcut, s.text_size);
		painter.text({ elem.size.x - s.pad_x - hint.x, text_y }, self.item.shortcut, {
			.font = s.font, .size = s.text_size, .color = s.dim_color,
		});
	}
}

fn void MenuItemRow.on_hover(&self, Element* elem, bool entered) @dynamic
{
	self.hovered = entered;
	// A disabled row asks for nothing rather than for the arrow, leaving the
	// panel underneath to answer — the arrow is what the panel already wants,
	// and DEFAULT keeps that one decision in one place.
	if (entered && !self.item.disabled) elem.set_cursor(Cursor.POINTING_HAND);
	elem.request_paint();
}

fn bool MenuItemRow.on_mouse(&self, Element* elem, MouseEvent event) @dynamic
{
	switch (event.kind)
	{
		case PRESS:
			// Consumed even when disabled: a dead item still must not close the
			// menu by letting the press fall through to the catcher.
			return event.button == MouseButton.LEFT;
		case RELEASE:
			if (event.button != MouseButton.LEFT) return false;
			MenuBar* bar = self.bar.widget_as(MenuBar);

			// The release belonging to the press that opened this dropdown, with
			// the pointer still where it was: the user has clicked the title, not
			// chosen an item, and only a panel placed over its own bar can put a
			// row under that press at all. Swallowed, so the menu stays open.
			bool arming = bar.arming;
			Vec2 drift = event.absolute - bar.armed_at;
			bar.arming = false;
			if (arming && math::abs(drift.x) <= MENU_ARM_SLOP && math::abs(drift.y) <= MENU_ARM_SLOP) return true;

			bool inside = event.pos.x >= 0 && event.pos.y >= 0
				&& event.pos.x < elem.size.x && event.pos.y < elem.size.y;
			if (inside && !self.item.disabled)
			{
				if (self.item.on_select) self.item.on_select(elem.ui);
				bar.open = 0;
				self.bar.request_build();
			}
			return true;
		default:
			return false;
	}
}

<*
 A divider between item groups. Internal.
*>
struct MenuSeparator (Widget)
{
	MenuStyle style;
	Vec2 size; // sized by the field convention: the dropdown sets row width × SEPARATOR_H
}

fn void MenuSeparator.paint(&self, Element* elem, Painter* painter) @dynamic
{
	float y = elem.size.y * 0.5f;
	painter.rect({ self.style.pad_x, y }, { elem.size.x - 2 * self.style.pad_x, 1 }, {
		.color = self.style.bar_border,
	});
}

// ---------------------------------------------------------------------------
// Select — a dropdown chooser.

<*
 A dropdown selector: a button showing the current option; open, a popup list
 of all of them. The chosen index lives on the widget, and `on_change` fires
 with it — reach the app through `ui.inherit`, as everywhere in this file.

 Same escape-the-rect trick as MenuBar, with one wrinkle: a Select sits at an
 arbitrary place in the tree, so its close-catcher reaches the window origin by
 offsetting itself by -elem.absolute — a value from the previous emit, so it can
 be one frame stale. That is invisible in practice (the Select has not moved
 between the click that opened it and the next frame), and it is the price of a
 popup with no overlay layer in the core.

 Because it sits anywhere, the list is placed against the screen rather than
 simply hung below the head: near the bottom edge it opens upwards instead. See
 `Media.drop`.

 While open, the built subtree paints in this element's slot in the paint order:
 siblings painted later can still cover the popup. Keep an open Select out from
 under overlapping later siblings — in a plain form layout there are none.
*>
struct Select (Widget)
{
	String[] options; // borrowed
	usz selected;
	OnSelect on_change;
	MenuStyle style;
	float width; // 0 = size to the widest option
	bool open;
}

fn float Select.head_width(&self, Ui* ui, MenuStyle s)
{
	if (self.width > 0) return self.width;
	float widest = 0;
	foreach (option : self.options)
	{
		widest = math::max(widest, ui.text.measure(s.font, option, s.text_size).x);
	}
	return widest + 2 * s.pad_x + 16.0f; // 16 = room for the chevron
}

fn Element* Select.build(&self, Element* elem) @dynamic
{
	MenuStyle s = self.style.resolved();
	Ui* ui = elem.ui;
	float w = self.head_width(ui, s);
	usz pick = self.selected < self.options.len ? self.selected : self.options.len - 1;
	String current = self.options.len > 0 ? self.options[pick] : "";

	if (!self.open)
	{
		return @subtree(ui)
		{
			@node((SelectHead) { .text = current, .style = s, .width = w });
		};
	}

	// Below the head, or above it when the list is taller than the room left
	// under it — a chooser near the bottom of the screen opens upwards instead
	// of off the edge. Local coordinates, so the head's own position comes back
	// out of the absolute answer.
	Vec2 list_size = { w, (float)self.options.len * s.item_height + 2 * PANEL_PAD_Y };
	Vec2 list_at = elem.media().drop(elem.absolute, s.item_height, list_size) - elem.absolute;

	return @subtree(ui)
	{
		@tree((Stack) { .size = { w, s.item_height } })
		{
			@node((SelectCatcher) { .host = elem })
				.set_offset({ -elem.absolute.x, -elem.absolute.y });
			@node((SelectHead) { .text = current, .style = s, .width = w });
			@tree((PopupPanel) {
				.style = {
					.color = s.panel_color,
					.border_width = 1.0,
					.border_color = s.panel_border,
					.border_radius = { 0.0, 0.0, 6.0, 6.0 },
				},
				.insets = { 0.0, PANEL_PAD_Y, 0.0, PANEL_PAD_Y },
				.shadow = POPUP_SHADOW,
				.shadow_color = { 0.0, 0.0, 0.0, 0.45 },
			})
			{
				@tree((Column) { })
				{
					foreach (i, option : self.options)
					{
						@node((SelectOption) {
							.text = option,
							.style = s,
							.width = w,
							.index = (usz)i,
							.chosen = (usz)i == self.selected,
							.host = elem,
						}).with_id(option);
					}
				};
			}.set_offset(list_at);
		};
	};
}

<*
 The head is inert; presses on it bubble here. Toggling from the composite
 rather than the head means the same press that opens also closes.
*>
fn bool Select.on_mouse(&self, Element* elem, MouseEvent event) @dynamic
{
	switch (event.kind)
	{
		case PRESS:
			if (event.button != MouseButton.LEFT) return false;
			self.open = !self.open;
			elem.request_build();
			return true;
		case RELEASE:
			return event.button == MouseButton.LEFT;
		default:
			return false;
	}
}

<*
 Dismisses the open list, if there is one. Safe to call when nothing is open.

 The same service `MenuBar.close` provides, and public for the same reason: a
 Select's click catcher is placed against the window, so a pane that clips its
 subtree leaves the list hanging when the press lands outside the pane. An app
 that puts one inside a clipped region needs a way to say "close whatever is
 open" from wherever the press did land.

 @param elem : `The Select's element — the one that rebuilds.`
*>
fn void Select.close(&self, Element* elem)
{
	if (!self.open) return;
	self.open = false;
	elem.request_build();
}

fn bool Select.on_key(&self, Element* elem, KeyEvent event) @dynamic
{
	if (self.open && event.down && event.key == Key.ESCAPE)
	{
		self.open = false;
		elem.request_build();
		return true;
	}
	return false;
}

<*
 The closed face of a Select: box, current text, chevron. Internal, and inert —
 its clicks are the composite's.
*>
struct SelectHead (Widget)
{
	String text;
	MenuStyle style;
	float width;
	bool hovered;
}

fn Vec2 SelectHead.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	return constraints.constrain({ self.width, self.style.item_height });
}

fn void SelectHead.paint(&self, Element* elem, Painter* painter) @dynamic
{
	MenuStyle s = self.style;
	painter.rect({ 0, 0 }, elem.size, {
		.color = self.hovered ? s.hover_color : s.open_color,
		.border_width = 1.0,
		.border_color = s.panel_border,
		.border_radius = { 5.0, 5.0, 5.0, 5.0 },
	});
	Vec2 text = elem.ui.text.measure(s.font, self.text, s.text_size);
	painter.text({ s.pad_x, (elem.size.y - text.y) * 0.5f }, self.text, {
		.font = s.font, .size = s.text_size, .color = s.text_color,
	});

	float cx = elem.size.x - s.pad_x - 3.0f;
	float cy = elem.size.y * 0.5f;
	painter.line({ cx - 4.0f, cy - 2.0f }, { cx, cy + 2.5f }, 1.4f, s.dim_color);
	painter.line({ cx, cy + 2.5f }, { cx + 4.0f, cy - 2.0f }, 1.4f, s.dim_color);
}

fn void SelectHead.on_hover(&self, Element* elem, bool entered) @dynamic
{
	self.hovered = entered;
	if (entered) elem.set_cursor(Cursor.POINTING_HAND);
	elem.request_paint();
}

<*
 One option in an open Select. Internal.
*>
struct SelectOption (Widget)
{
	String text;
	MenuStyle style;
	float width;
	usz index;
	bool chosen;
	Element* host; // the Select element
	bool hovered;
}

fn Vec2 SelectOption.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	return constraints.constrain({ self.width, self.style.item_height });
}

fn void SelectOption.paint(&self, Element* elem, Painter* painter) @dynamic
{
	MenuStyle s = self.style;
	if (self.hovered)
	{
		painter.rect({ 2, 0 }, { elem.size.x - 4, elem.size.y }, {
			.color = s.hover_color,
			.border_radius = { 4.0, 4.0, 4.0, 4.0 },
		});
	}
	if (self.chosen)
	{
		painter.circle({ 12.0, elem.size.y * 0.5f }, 2.5f, { .color = s.text_color });
	}
	Vec2 text = elem.ui.text.measure(s.font, self.text, s.text_size);
	painter.text({ CHECK_GUTTER, (elem.size.y - text.y) * 0.5f }, self.text, {
		.font = s.font, .size = s.text_size, .color = s.text_color,
	});
}

fn void SelectOption.on_hover(&self, Element* elem, bool entered) @dynamic
{
	self.hovered = entered;
	if (entered) elem.set_cursor(Cursor.POINTING_HAND);
	elem.request_paint();
}

fn bool SelectOption.on_mouse(&self, Element* elem, MouseEvent event) @dynamic
{
	switch (event.kind)
	{
		case PRESS:
			return event.button == MouseButton.LEFT;
		case RELEASE:
			if (event.button != MouseButton.LEFT) return false;
			bool inside = event.pos.x >= 0 && event.pos.y >= 0
				&& event.pos.x < elem.size.x && event.pos.y < elem.size.y;
			if (inside)
			{
				Select* select = self.host.widget_as(Select);
				select.selected = self.index;
				select.open = false;
				if (select.on_change) select.on_change(elem.ui, self.index);
				self.host.request_build();
			}
			return true;
		default:
			return false;
	}
}

<*
 The click-anywhere-else-closes surface of an open Select. Internal. Its layout
 deliberately answers with the window size, ignoring the constraints it was
 offered — it is an overlay pretending the tree has an overlay layer, and its
 offset (set by Select.build) walks it back to the window origin.
*>
struct SelectCatcher (Widget)
{
	Element* host; // the Select element
}

fn Vec2 SelectCatcher.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	return elem.ui.size;
}

fn bool SelectCatcher.on_mouse(&self, Element* elem, MouseEvent event) @dynamic
{
	if (event.kind != MouseEventKind.PRESS && event.kind != MouseEventKind.RELEASE) return false;
	if (event.kind == MouseEventKind.PRESS)
	{
		Select* select = self.host.widget_as(Select);
		select.open = false;
		self.host.request_build();
	}
	return true;
}
