<*
 A menu that opens where the pointer is: the right-click menu, and the "add a
 node" search of a node editor.

 Mount one near the root, where it will paint over everything — a later
 sibling of the panels it serves — and open it from any handler with
 `open_at(elem, point)`, passing a point on screen (`MouseEvent.absolute`, or
 `Element.to_screen` from inside a zoomed canvas). Find its element again with
 an id: `ui.find_id("add-node")`.

 Items are borrowed and given in display order. Consecutive items with the
 same `category` are grouped under a header naming it. With `searchable`, a
 field at the top takes the keyboard as the menu opens and narrows the list as
 it is typed into — matching the label or the category, ignoring case — and the
 headers give way to the category shown beside each match.

 Keys: Up and Down move the highlight, Return chooses it, Esc dismisses. A
 click outside dismisses too. `on_choose` gets the index into `items`;
 `on_dismiss` is called for a close that chose nothing.

 Placement: at the point, clamped onto the screen so the whole panel shows.
 Taller lists than `max_height` scroll with the wheel, and follow the
 highlight.
*>
module cui::widgets;
import std::math;

import cui;

<*
 One entry of a `ContextMenu`.
*>
struct ContextMenuItem
{
	String label; // borrowed
	String category; // borrowed; "" = ungrouped
	String hint; // borrowed; dim text on the right, e.g. a shortcut
	bool disabled;
}

<*
 An item was chosen: its index into `ContextMenu.items`.
*>
alias OnMenuChoose = fn void(Ui* ui, usz index);

const float CONTEXT_MENU_WIDTH = 260.0;
const float CONTEXT_MENU_MAX_HEIGHT = 380.0;
// The height of a category header, as a fraction of an item row.
const float CONTEXT_HEADER_RATIO = 0.8;

struct ContextMenu (Widget)
{
	ContextMenuItem[] items; // borrowed
	OnMenuChoose on_choose;
	OnClick on_dismiss;
	MenuStyle style;
	float width; // 0 = CONTEXT_MENU_WIDTH
	float max_height; // of the list; 0 = CONTEXT_MENU_MAX_HEIGHT
	bool searchable;
	String placeholder; // the empty search field's prompt; "" = "Search"

	// State: whether it is open and where, what has been typed, and which
	// item the keyboard has highlighted (an index into `items`, -1 = none).
	bool open;
	Vec2 at;
	char[SELECT_QUERY_MAX] query_buf;
	usz query_len;
	sz active;
	bool return_held;
	Element* list; // the open list's element, so a key can repaint it
}

<*
 The current search text.
*>
fn String ContextMenu.query(&self) => (String)self.query_buf[:self.query_len];

<*
 Opens the menu with its top-left at a point on screen, with an empty search
 and the first item highlighted. Reopening an open menu moves it.

 @param elem : `The menu's element.`
 @param at : `UI coordinates.`
*>
fn void ContextMenu.open_at(&self, Element* elem, Vec2 at)
{
	self.open = true;
	self.at = at;
	self.query_len = 0;
	self.active = self.next_match(-1, 1);
	self.return_held = elem.ui.input.key_down(Key.RETURN);
	elem.request_build();
	elem.request_focus();
}

<*
 Closes the menu without choosing anything, calling `on_dismiss`. Safe to call
 when it is closed.

 @param elem : `The menu's element.`
*>
fn void ContextMenu.dismiss(&self, Element* elem)
{
	if (!self.open) return;
	self.close(elem);
	if (self.on_dismiss) self.on_dismiss(elem.ui);
}

<*
 Closes the menu, quietly. Safe to call when it is closed.

 @param elem : `The menu's element.`
*>
fn void ContextMenu.close(&self, Element* elem)
{
	if (!self.open) return;
	self.open = false;
	self.list = null;
	elem.request_build();
}

<*
 Chooses an item: closes the menu, then calls `on_choose`.

 @param elem : `The menu's element.`
 @param index : `Into items.`
*>
fn void ContextMenu.choose(&self, Element* elem, usz index)
{
	if (index >= self.items.len || self.items[index].disabled) return;
	self.close(elem);
	if (self.on_choose) self.on_choose(elem.ui, index);
}

<*
 Whether an item passes the current search.

 @param index : `Into items.`
*>
fn bool ContextMenu.matches(&self, usz index)
{
	String q = self.query();
	if (q.len == 0) return true;
	ContextMenuItem item = self.items[index];
	return contains_fold(item.label, q) || contains_fold(item.category, q);
}

<*
 The next item after `from` (or before it, with `direction` -1) that passes
 the search and is enabled; -1 when there is none.

 @param from : `An index into items, or -1 to start from the end the direction leaves.`
 @param direction : `1 or -1.`
*>
fn sz ContextMenu.next_match(&self, sz from, int direction)
{
	sz n = (sz)self.items.len;
	sz i = from;
	if (i < 0) i = direction > 0 ? -1 : n;
	for (;;)
	{
		i += direction;
		if (i < 0 || i >= n) return -1;
		if (!self.items[i].disabled && self.matches((usz)i)) return i;
	}
}

<*
 The search text changed: keep it, and highlight the first match.

 @param text : `What the field holds now.`
*>
fn void ContextMenu.set_query(&self, String text)
{
	usz n = text.len < SELECT_QUERY_MAX ? text.len : SELECT_QUERY_MAX;
	foreach (usz i, char c : text[:n]) self.query_buf[i] = c;
	self.query_len = n;
	self.active = self.next_match(-1, 1);
	if (self.list)
	{
		ContextMenuList* list = self.list.widget_as(ContextMenuList);
		list.scroll = 0;
		self.list.request_layout();
	}
}

fn Element* ContextMenu.build(&self, Element* elem) @dynamic
{
	Ui* ui = elem.ui;
	elem.raised = self.open;
	if (!self.open) return ui.@node((Stack) { });

	MenuStyle s = self.style.resolved();
	float w = self.width > 0 ? self.width : CONTEXT_MENU_WIDTH;
	return @subtree(ui)
	{
		@tree((Stack) { })
		{
			@node((ContextCatcher) { .host = elem });
			@tree(
				(PopupPanel) {
					.style = {
						.color = s.panel_color,
						.border_width = 1.0,
						.border_color = s.panel_border,
						.border_radius = { 6.0, 6.0, 6.0, 6.0 },
					},
					.insets = { 0.0, PANEL_PAD_Y, 0.0, PANEL_PAD_Y },
					.shadow = POPUP_SHADOW,
					.shadow_color = { 0.0, 0.0, 0.0, 0.45 },
				}
			)
			{
				@tree((Column) { })
				{
					if (self.searchable)
					{
						@node((ContextSearch) { .host = elem, .style = s, .width = w });
					}
					@node((ContextMenuList) { .host = elem, .style = s, .width = w });
				};
			};
		};
	};
}

<*
 Places the catcher over the whole window and the panel at the opening point,
 kept on screen. The element itself takes no room.
*>
fn Vec2 ContextMenu.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	if (!self.open)
	{
		elem.layout_child(0, cui::tight({ 0, 0 }));
		return { 0, 0 };
	}
	// The Stack holding catcher and panel, walked back to the window origin —
	// the previous emit's `absolute`, the Select caveat.
	// Seen through any zoom above the menu, though one mounted near the root
	// as intended has none.
	Element* stack = elem.children[0];
	Vec4 window = elem.window_box();
	elem.layout_child(0, cui::tight({ window.z - window.x, window.w - window.y }));
	elem.place_child(0, { window.x, window.y });
	Element* panel = stack.children[1];
	Media m = elem.media();
	Vec2 at = m.clamp_rect(self.at, panel.size);
	panel.set_offset(elem.to_local(at) - (Vec2) { window.x, window.y });
	return { 0, 0 };
}

fn bool ContextMenu.on_key(&self, Element* elem, KeyEvent event) @dynamic
{
	if (!self.open || !event.down) return false;
	switch (event.key)
	{
		case Key.ESCAPE:
			self.dismiss(elem);
		case Key.UP_ARROW:
		case Key.DOWN_ARROW:
			int direction = event.key == Key.UP_ARROW ? -1 : 1;
			sz next = self.next_match(self.active, direction);
			if (next >= 0) self.active = next;
			if (self.list) self.list.widget_as(ContextMenuList).reveal_active(self.list);
		case Key.RETURN:
		case Key.KP_RETURN:
			if (!self.return_held && self.active >= 0) self.choose(elem, (usz)self.active);
			self.return_held = true;
		default:
			// The menu is modal while open: a key meant for it must not run an
			// app shortcut behind it.
			break;
	}
	return true;
}

<*
 Return with the search field focused: the field takes the key and submits
 nothing we can hear, so the edge is read off the held keys instead.
*>
fn void ContextMenu.update(&self, Element* elem, float dt) @dynamic
{
	bool down = elem.ui.input.key_down(Key.RETURN) || elem.ui.input.key_down(Key.KP_RETURN);
	if (self.open && down && !self.return_held && self.active >= 0) self.choose(elem, (usz)self.active);
	self.return_held = down;
}

<*
 The click-anywhere-else surface of an open menu. Internal.
*>
struct ContextCatcher (Widget)
{
	Element* host;
}

fn bool ContextCatcher.on_mouse(&self, Element* elem, MouseEvent event) @dynamic
{
	if (event.kind == MouseEventKind.PRESS) self.host.widget_as(ContextMenu).dismiss(self.host);
	return event.kind != MouseEventKind.MOVE;
}

<*
 The search field at the top of a searchable menu. Internal; copies what is
 typed into the menu's query each frame, the SelectSearch arrangement.
*>
struct ContextSearch (Widget)
{
	Element* host;
	MenuStyle style;
	float width;
	bool focused;
}

fn Element* ContextSearch.build(&self, Element* elem) @dynamic
{
	ContextMenu* menu = self.host.widget_as(ContextMenu);
	return @subtree(elem.ui)
	{
		@node(
			(TextField) {
				.placeholder = menu.placeholder.len > 0 ? menu.placeholder : "Search",
				.style = select_search_style(self.style),
			}
		);
	};
}

fn Vec2 ContextSearch.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	Vec2 field = elem.layout_child(0, cui::loose({ self.width - 2 * SELECT_SEARCH_MARGIN, cui::UNBOUNDED }));
	elem.place_child(0, { SELECT_SEARCH_MARGIN, SELECT_SEARCH_MARGIN });
	return { self.width, field.y + 2 * SELECT_SEARCH_MARGIN };
}

fn void ContextSearch.update(&self, Element* elem, float dt) @dynamic
{
	if (elem.children.len() == 0) return;
	Element* field_elem = elem.children[0];
	if (!self.focused)
	{
		field_elem.request_focus();
		self.focused = true;
	}
	ContextMenu* menu = self.host.widget_as(ContextMenu);
	String typed = field_elem.widget_as(TextField).value();
	if (typed != menu.query()) menu.set_query(typed);
}

<*
 The rows of an open menu: headers and items, narrowed by the search,
 scrolling inside the menu's `max_height`. Internal; one painted element rather
 than an element per row, so a search re-filters with a layout and no rebuild.
*>
struct ContextMenuList (Widget)
{
	Element* host;
	MenuStyle style;
	float width;
	float scroll;
	sz hovered; // index into items, -1 = none
	bool pressed;
}

<*
 Walks the visible rows top to bottom, giving each its y, height, and the item
 it shows (-1 for a header, whose category is the label). The body is inlined
 into the walk, so it must not `continue` — that would skip the walk's own
 bookkeeping.
*>
macro void ContextMenuList.@rows(&self, ContextMenu* menu; @body(float y, float h, sz item, String label))
{
	MenuStyle s = self.style;
	bool grouped = menu.query_len == 0;
	float y = 0;
	String category = "";
	bool first = true;
	foreach (i, item : menu.items)
	{
		if (!menu.matches((usz)i)) continue;
		if (grouped && item.category.len > 0 && (first || item.category != category))
		{
			float hh = s.item_height * CONTEXT_HEADER_RATIO;
			@body(y, hh, -1, item.category);
			y += hh;
		}
		category = item.category;
		first = false;
		@body(y, s.item_height, (sz)i, item.label);
		y += s.item_height;
	}
}

fn float ContextMenuList.content_height(&self, ContextMenu* menu)
{
	float total = 0;
	self.@rows(menu; float y, float h, sz item, String label)
	{
		total = y + h;
	};
	return total;
}

fn void ContextMenuList.mount(&self, Element* elem) @dynamic
{
	self.hovered = -1;
}

fn Vec2 ContextMenuList.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	ContextMenu* menu = self.host.widget_as(ContextMenu);
	menu.list = elem;
	elem.clips = true;
	float max_h = menu.max_height > 0 ? menu.max_height : CONTEXT_MENU_MAX_HEIGHT;
	float content = self.content_height(menu);
	float h = content == 0 ? self.style.item_height : math::min(content, max_h);
	self.scroll = math::clamp(self.scroll, 0.0f, math::max(content - h, 0.0f));
	return { self.width, h };
}

fn void ContextMenuList.unmount(&self, Element* elem) @dynamic
{
	ContextMenu* menu = self.host.widget_as(ContextMenu);
	if (menu.list == elem) menu.list = null;
}

fn void ContextMenuList.paint(&self, Element* elem, Painter* painter) @dynamic
{
	ContextMenu* menu = self.host.widget_as(ContextMenu);
	MenuStyle s = self.style;
	bool any_row;
	self.@rows(menu; float y, float h, sz item, String label)
	{
		any_row = true;
		float top = y - self.scroll;
		if (top + h >= 0 && top <= elem.size.y) self.paint_row(elem, painter, menu, top, h, item, label);
	};
	if (!any_row)
	{
		Vec2 m = elem.ui.text.measure(s.font, "No matches", s.text_size);
		painter.text({ s.pad_x, (elem.size.y - m.y) * 0.5f }, "No matches",
			{ .font = s.font, .size = s.text_size, .color = s.dim_color });
	}
}

<*
 One row, at `top` in the list's pixels: a header (`item` -1) or an item.
*>
fn void ContextMenuList.paint_row(&self, Element* elem, Painter* painter, ContextMenu* menu, float top, float h, sz item, String label)
{
	MenuStyle s = self.style;
	if (item < 0)
	{
		Vec2 m = elem.ui.text.measure(s.font, label, s.text_size - 2);
		painter.text({ s.pad_x, top + (h - m.y) * 0.5f + 1 }, label,
			{ .font = s.font, .size = s.text_size - 2, .color = s.dim_color });
		return;
	}
	ContextMenuItem it = menu.items[item];
	bool lit = item == menu.active || item == self.hovered;
	if (lit && !it.disabled)
	{
		painter.rect({ 4, top }, { elem.size.x - 8, h },
			{ .color = s.hover_color, .border_radius = { 4.0, 4.0, 4.0, 4.0 } });
	}
	Color ink = it.disabled ? s.dim_color : s.text_color;
	float indent = menu.query_len == 0 && it.category.len > 0 ? s.pad_x + 8 : s.pad_x;
	Vec2 m = elem.ui.text.measure(s.font, label, s.text_size);
	float ty = top + (h - m.y) * 0.5f;
	// The right-hand note: the item's hint, or its category while searching
	// has taken the headers away.
	String note = it.hint.len > 0 ? it.hint : (menu.query_len > 0 ? it.category : "");
	float note_w = note.len > 0 ? elem.ui.text.measure(s.font, note, s.text_size - 1).x + s.pad_x : 0;
	painter.text_box({ indent, ty }, label, { .font = s.font, .size = s.text_size, .color = ink },
		elem.size.x - indent - s.pad_x - note_w, ELLIPSIS);
	if (note.len > 0)
	{
		painter.text({ elem.size.x - note_w, ty + 1 }, note,
			{ .font = s.font, .size = s.text_size - 1, .color = s.dim_color });
	}
}

<*
 The item row under a point in the list's own pixels, or -1.
*>
fn sz ContextMenuList.item_at(&self, ContextMenu* menu, Vec2 pos)
{
	sz found = -1;
	float at = pos.y + self.scroll;
	self.@rows(menu; float y, float h, sz item, String label)
	{
		if (item >= 0 && at >= y && at < y + h) found = item;
	};
	return found;
}

<*
 Scrolls so the highlighted item is in view.
*>
fn void ContextMenuList.reveal_active(&self, Element* elem)
{
	ContextMenu* menu = self.host.widget_as(ContextMenu);
	self.@rows(menu; float y, float h, sz item, String label)
	{
		if (item == menu.active)
		{
			if (y < self.scroll) self.scroll = y;
			if (y + h > self.scroll + elem.size.y) self.scroll = y + h - elem.size.y;
		}
	};
	elem.request_paint();
}

fn void ContextMenuList.on_hover(&self, Element* elem, bool entered) @dynamic
{
	if (entered) return;
	self.hovered = -1;
	elem.request_paint();
}

fn bool ContextMenuList.on_mouse(&self, Element* elem, MouseEvent event) @dynamic
{
	ContextMenu* menu = self.host.widget_as(ContextMenu);
	switch (event.kind)
	{
		case MOVE:
			sz at = self.item_at(menu, event.pos);
			if (at >= 0 && menu.items[at].disabled) at = -1;
			if (at != self.hovered)
			{
				self.hovered = at;
				elem.set_cursor(at >= 0 ? Cursor.POINTING_HAND : Cursor.DEFAULT);
				elem.request_paint();
			}
			return false;
		case SCROLL:
			self.scroll = math::clamp(self.scroll - event.scroll * menu.style.resolved().item_height,
				0.0f, math::max(self.content_height(menu) - elem.size.y, 0.0f));
			elem.request_paint();
			return true;
		case PRESS:
			if (event.button != MouseButton.LEFT) return true;
			self.pressed = true;
			return true;
		case RELEASE:
			if (event.button != MouseButton.LEFT || !self.pressed) return true;
			self.pressed = false;
			bool inside = event.pos.x >= 0 && event.pos.y >= 0 && event.pos.x < elem.size.x && event.pos.y < elem.size.y;
			sz at = inside ? self.item_at(menu, event.pos) : -1;
			if (at >= 0) menu.choose(self.host, (usz)at);
			return true;
	}
}
