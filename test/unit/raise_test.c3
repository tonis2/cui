// Raising: a popup opened deep inside a form has to come out over the rows
// below the form, not only over the field beside it — and the floors an
// embedder built out of siblings have to keep the order it wrote them in.
// Paint order is read straight off `Element.first_drawing`, which is where
// emit put each element's drawings in `ui.canvas`.
module cui_tests::raises;
import cui;
import cui_tests;
import std::core::test;

// The shape the bug lived in: a chooser two containers deep, with more of the
// form under it. Without the climb the raise only beat the label beside it.
fn void a_raise_climbs_to_its_ancestors() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	Element* popup = ui.@node((Rectangle){ .size = {100, 50} });
	Element* row = ui.@node((Row){}, popup);
	Element* under = ui.@node((Rectangle){ .size = {100, 50} });
	ui.build(ui.@node((Stack){}, ui.@node((Column){}, row, under)));

	// The control first: nothing raised, so the form paints top to bottom.
	ui.flush();
	test::@check(popup.first_drawing < under.first_drawing, "unraised, the row paints first");

	popup.raised = true;
	popup.request_paint();
	ui.flush();
	test::@check(popup.first_drawing > under.first_drawing, "raised, the popup paints last");
	test::@check(row.raise_path, "the raise reached the row");
	test::@check(!under.raise_path, "and nothing else");
}

// The hit test walks in reverse paint order, so the same climb has to move the
// click: a popup that is drawn over a field must also take that field's press.
fn void a_raised_popup_takes_the_click() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	EventRecord popup_rec;
	EventRecord under_rec;

	// The popup hangs below the head that owns it, over the field under it —
	// which is what a dropdown is. A Stack lays its children out without placing
	// them, so the offset survives layout.
	Element* popup = ui.@node((EventProbe){ .pref = {100, 50}, .rec = &popup_rec });
	popup.set_offset({0, 50});
	Element* head = ui.@node((Stack){ .size = {100, 50} }, popup);
	Element* under = ui.@node((EventProbe){ .pref = {100, 50}, .rec = &under_rec });
	ui.build(ui.@node((Stack){}, ui.@node((Column){}, head, under)));
	ui.flush();

	test::eq(ui.hit_test({50, 75}), under);

	popup.raised = true;
	popup.request_paint();
	ui.flush();
	test::eq(ui.hit_test({50, 75}), popup);
}

// Floors are siblings, and a raise inside one lifts that whole floor — so the
// order between floors has to survive it. Both floors hold a raise here (a
// dropdown on the HUD, a modal on the layer above), and the modal still wins.
fn void floors_keep_their_order() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	Element* dropdown = ui.@node((Rectangle){ .size = {100, 50} });
	dropdown.raised = true;
	Element* hud = ui.@node((Stack){}, dropdown);

	Element* modal = ui.@node((Rectangle){ .size = {100, 50} });
	modal.raised = true;
	Element* dialogs = ui.@node((Stack){}, modal);

	ui.build(ui.@node((Stack){}, hud, dialogs));
	ui.flush();

	test::@check(hud.raise_path && dialogs.raise_path, "both floors carry a raise");
	test::@check(modal.first_drawing > dropdown.first_drawing, "the later floor still paints last");
	test::eq(ui.hit_test({50, 25}), modal);
}
