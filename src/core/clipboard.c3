module cui;

// The clipboard: what a text field's ctrl+c, ctrl+x and ctrl+v go through.
//
// cui has no window to ask, so the embedder provides one - `ui.provide(&clip)`
// with a `Clipboard` whose functions reach the system's. Without one, a copy is
// kept here and is pasteable inside this process only, which is still what a
// person expects from copying one field into another.

alias ClipboardRead = fn String(void* user, Allocator alloc);
alias ClipboardWrite = fn void(void* user, String text);

<*
 The system clipboard as the embedder reaches it. Provided with `Ui.provide`;
 `user` is handed back to both functions.
*>
struct Clipboard
{
	ClipboardRead read;
	ClipboardWrite write;
	void* user;
}

String local_clipboard @local;

<*
 Put text on the clipboard.
*>
fn void Ui.clipboard_write(&self, String text)
{
	if (try clip = self.inherit(Clipboard))
	{
		if (clip.write)
		{
			clip.write(clip.user, text);
			return;
		}
	}
	if (local_clipboard.ptr != null) local_clipboard.free(mem);
	local_clipboard = text.copy(mem);
}

<*
 The clipboard's text, allocated with `alloc`; empty when it holds none.
*>
fn String Ui.clipboard_read(&self, Allocator alloc)
{
	if (try clip = self.inherit(Clipboard))
	{
		if (clip.read) return clip.read(clip.user, alloc);
	}
	return local_clipboard.copy(alloc);
}
