<*
 What the built-in widgets say about themselves to `Ui.describe_tree` and
 `Ui.find_text`: the text a person would read, and the state they would see.
*>
module cui::widgets;
import cui;
import std::core::string;

fn String on_off(bool on) @local => on ? "on" : "off";

fn void Label.describe(&self, Element* elem, Description* out) @dynamic => out.text = self.text;
fn void LiveLabel.describe(&self, Element* elem, Description* out) @dynamic => out.text = self.shown;
fn void Button.describe(&self, Element* elem, Description* out) @dynamic => out.text = self.label;
fn void Tooltip.describe(&self, Element* elem, Description* out) @dynamic => out.text = self.text;
fn void MenuTitle.describe(&self, Element* elem, Description* out) @dynamic => out.text = self.title;
fn void SelectOption.describe(&self, Element* elem, Description* out) @dynamic => out.text = self.text;

fn void Checkbox.describe(&self, Element* elem, Description* out) @dynamic
{
	out.text = self.label;
	out.value = on_off(self.checked);
}

fn void ToggleButton.describe(&self, Element* elem, Description* out) @dynamic
{
	out.text = self.label;
	out.value = on_off(self.on);
}

fn void Disclosure.describe(&self, Element* elem, Description* out) @dynamic
{
	out.text = self.label;
	out.value = self.expanded ? "open" : "closed";
}

fn void TextField.describe(&self, Element* elem, Description* out) @dynamic
{
	out.text = self.placeholder;
	out.value = string::tformat("\"%s\"", self.value());
}

fn void Slider.describe(&self, Element* elem, Description* out) @dynamic
{
	out.text = self.label;
	out.value = string::tformat("%.3f%s", self.value, self.disabled ? " disabled" : "");
}

fn void Select.describe(&self, Element* elem, Description* out) @dynamic
{
	if (self.selected < self.options.len) out.text = self.options[self.selected];
	out.value = self.open ? "open" : "";
}

fn void PopupMenuItem.describe(&self, Element* elem, Description* out) @dynamic
{
	out.text = self.item.label;
	out.value = self.item.disabled ? "disabled" : self.item.checked ? "on" : "";
}

fn void MenuItemRow.describe(&self, Element* elem, Description* out) @dynamic
{
	out.text = self.item.label;
	out.value = self.item.disabled ? "disabled" : self.item.checked ? "on" : "";
}

fn void Segmented.describe(&self, Element* elem, Description* out) @dynamic
{
	SegmentedStyle s = self.style.resolved();
	if (self.selected >= 0 && self.selected < self.options.len) out.value = self.options[self.selected];
	float left = 0;
	foreach (option : self.options)
	{
		float width = s.segment_width(elem.ui, option);
		out.part(option, { left, 0 }, { width, elem.size.y });
		left += width;
	}
}

fn void Steps.describe(&self, Element* elem, Description* out) @dynamic
{
	StepsStyle s = self.style.resolved();
	foreach (usz i, step : self.steps)
	{
		out.part(step.label, { self.step_left(elem, (sz)i), 0 }, { self.step_width(elem.ui, step, s), elem.size.y });
	}
}

fn void Tree.describe(&self, Element* elem, Description* out) @dynamic
{
	TreeStyle style = self.style.resolved();
	if (self.selected < self.rows.len) out.value = self.rows[self.selected].label;
	foreach (usz i, row : self.rows)
	{
		out.part(row.label, { 0, (float)i * style.row_height }, { elem.size.x, style.row_height });
	}
}

fn void FileBrowser.describe(&self, Element* elem, Description* out) @dynamic
{
	FileBrowserStyle style = self.style.resolved();
	out.value = self.directory.str_view();
	for (usz row = 0; row < self.rows(); row++)
	{
		usz index = self.entry_index((int)row);
		String name = index >= self.count() ? ".." : self.entries.get((sz)index).name;
		out.part(name, { 0, (float)row * style.row_height }, { elem.size.x, style.row_height });
	}
}

fn void NodeCard.describe(&self, Element* elem, Description* out) @dynamic
{
	NodeGraph* graph = self.graph(elem);
	if (self.node < graph.nodes.len) out.text = graph.nodes[self.node].title;
}
