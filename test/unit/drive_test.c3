// The driver: synthetic clicks, typing and keys, finding by id and by text,
// and the tree dump agents read.
module cui_tests::drive;
import cui;
import cui::widgets;
import std::core::test;
import std::core::dstring;

int clicks @local;
usz picked @local;

String[3] options @local = { "Smooth", "Linear", "Step" };

fn void note_click(Ui* ui) @local => clicks++;
fn void note_pick(Ui* ui, usz index) @local => picked = index;

fn Ui* form() @local
{
	Ui* ui = cui::new_ui({ 400, 300 });
	clicks = 0;
	picked = 99;
	@canvas(ui)
	{
		@tree((Column) { .gap = 4 })
		{
			@tree(widgets::tip("Save the file"))
			{
				@node((Button) { .size = { 80, 24 }, .label = "Save", .on_click = &note_click }).with_id("save");
			};
			@node((Checkbox) { .label = "Mirror", .size = { 120, 20 } }).with_id("mirror");
			@node((TextField) { .placeholder = "Name", .width = 200 }).with_id("name");
			@node((Segmented) { .options = options[..], .selected = 0, .on_change = &note_pick });
		};
	};
	ui.flush();
	return ui;
}

fn void click_by_id_and_by_tooltip() @test
{
	Ui* ui = form();
	defer ui.free();

	ui.click(ui.target_id("save")!!.center());
	test::eq(clicks, 1);

	int matches;
	DriveTarget t = ui.find_text("save the", &matches)!!;
	test::eq(matches, 1);
	ui.click(t.center());
	test::eq(clicks, 2);

	test::@check(@catch(ui.find_text("nothing here")) == cui::NO_SUCH_TARGET, "an unknown text is no target");
}

fn void a_checkbox_found_by_its_label_toggles() @test
{
	Ui* ui = form();
	defer ui.free();

	Checkbox* box = ui.find_id("mirror")!!.widget_as(Checkbox);
	ui.click(ui.find_text("Mirror")!!.center());
	test::eq(box.checked, true);
}

fn void typing_goes_to_the_clicked_field() @test
{
	Ui* ui = form();
	defer ui.free();

	Element* field = ui.find_id("name")!!;
	ui.click(field.drive_target().center());
	ui.type_text("hips");
	test::eq(field.widget_as(TextField).value(), "hips");
	ui.press_keys({ BACKSPACE });
	test::eq(field.widget_as(TextField).value(), "hip");
}

fn void segments_are_parts_found_by_text() @test
{
	Ui* ui = form();
	defer ui.free();

	ui.click(ui.find_text("Step")!!.center());
	test::eq(picked, (usz)2);
}

fn void the_tree_dump_names_what_can_be_used() @test
{
	Ui* ui = form();
	defer ui.free();

	DString out;
	out.init(mem);
	defer out.free();
	ui.describe_tree(&out)!!;
	String s = out.str_view();
	test::@check(s.contains("Button #save \"Save\""), "the button is listed: %s", s);
	test::@check(s.contains("Tooltip \"Save the file\""), "the tooltip is listed");
	test::@check(s.contains("Checkbox #mirror \"Mirror\" = off"), "the checkbox shows its state");
	test::@check(s.contains("part \"Linear\""), "segments are parts");
	// Layout-only containers say nothing and are left out.
	test::@check(!s.contains("Column"), "the column is left out");
}

fn void chords_parse_from_names() @test
{
	Key[4] buf;
	Key[] keys = cui::keys_from_chord("Ctrl+Shift+z", &buf)!!;
	test::eq(keys.len, 3);
	test::@check(keys[0] == Key.LEFT_CTRL, "ctrl first");
	test::@check(keys[2] == Key.Z, "z last");
	test::@check(@catch(cui::key_from_name("hyper")) == cui::UNKNOWN_KEY, "unknown names fail");
}
