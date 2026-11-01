<*
 What `ConfirmDialog` and `ChoiceDialog` share: a modal `Dialog` whose message
 is decided when the question is asked, copied out of whatever temporary the
 caller formatted. Embedded inline, so `dialog.message` reads through.
*>
module cui::widgets;

import cui;

// How wide the message runs before it wraps: a readability limit, not a taste.
const float CONFIRM_TEXT_W = 380.0;

// The inner Dialog, found by the question that built it. Scoped to that subtree
// by `Element.find_id`, so several in one tree do not collide.
const String QUESTION_PANEL_ID = "cui-question-panel";

struct Question
{
	DString message; // owned
	// Raised when `ask` runs before the inner Dialog exists; `build` consumes it.
	bool open_when_built;
	// Guards the dismiss callback against the close `withdraw` fires itself.
	bool withdrawing;
}

fn void Question.free(&self)
{
	if (self.message.data()) self.message.free();
}

<*
 The inner Dialog. Its open state lives there and nowhere here. A question is
 answered with a button, not a click beside it, so the backdrop does not close.

 @param host : "The question widget's element, handed back to body and dismissed"
*>
fn Element* Question.panel(&self, Element* host, String title, DialogStyle style, ViewBuilderCtx body, OnDialogClose dismissed)
{
	bool open = self.open_when_built;
	self.open_when_built = false;
	return host.ui.@node(
		(Dialog) {
			.title = title,
			.body_ctx = body,
			.ctx = host,
			.style = style,
			.modal = true,
			.open = open,
			.close_outside = false,
			.on_close_ctx = dismissed,
		}
	).with_id(QUESTION_PANEL_ID);
}

<*
 Puts the question up, or replaces the one that is up. The message is copied,
 so a `tformat` result is fine, and so is this question's own message coming
 back in.

 @param host : "The question widget's element"
*>
fn void Question.ask(&self, Element* host, String message)
{
	// Through temp memory: appending a slice of this very buffer back into it
	// would be an overlapping copy.
	String wanted = message.tcopy();
	if (!self.message.data()) self.message.init(mem);
	self.message.clear();
	self.message.append(wanted);

	if (try Element* panel = host.find_id(QUESTION_PANEL_ID))
	{
		Dialog* dialog = panel.widget_as(Dialog);
		// Already up: its text points into a buffer that just changed.
		if (dialog.open)
		{
			panel.request_build();
		}
		else
		{
			dialog.set_open(panel, true);
		}
		return;
	}
	self.open_when_built = true;
	host.request_build();
}

<*
 Whether the question is up.
*>
fn bool Question.asking(&self, Element* host)
{
	if (try Element* panel = host.find_id(QUESTION_PANEL_ID)) return panel.widget_as(Dialog).open;
	return self.open_when_built;
}

<*
 Takes the question down without running the dismiss callback.
*>
fn void Question.withdraw(&self, Element* host)
{
	self.open_when_built = false;
	if (try Element* panel = host.find_id(QUESTION_PANEL_ID))
	{
		self.withdrawing = true;
		panel.widget_as(Dialog).set_open(panel, false);
		self.withdrawing = false;
	}
}

<*
 The body: the message wrapped at CONFIRM_TEXT_W, then the answers against the
 right edge.
*>
fn Element* Question.content(&self, Ui* ui, DialogStyle s, float gap, Element* answers)
{
	return ui.@node(
		(Column) { .size = { CONFIRM_TEXT_W, 0 }, .gap = gap },
		ui.@node((Label) {
			.text = self.message.str_view(),
			.font = s.font,
			.size = s.text_size,
			.color = s.text_color,
			.overflow = WRAP,
		}),
		answers
	);
}
