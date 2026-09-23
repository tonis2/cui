// Select: a long list is capped to the screen and scrolls (rather than running
// off the edge), opens on the current option, and — when searchable — narrows to
// a typed query while the field beside it keeps its focus.
// 
// No font is loaded in a headless Ui, so measured text is zero-width and every
// row is one `item_height` tall: the geometry here is the item height and the
// window, nothing softer.
module cui_tests::selects;
import cui;
import cui::widgets;
import cui_tests;
import std::math;
import std::core::test;

// What `on_change` reported — a bare OnSelect carries no context, so it lands
// here.
usz chosen_index @local;
int chosen_count @local;

fn void note_choice(Ui* ui, usz index) @local
{
	chosen_index = index;
	chosen_count++;
}

// Build a Select under a window-filling Stack and open it with a press-release on
// its head. Returns the Select element.
fn Element* open_select(
	Ui* ui,
	String[] options,
	bool searchable = false,
	usz selected = 0,
	float width = 160,
	OnSelect on_change = null
) @local
{
	Element* elem = ui.@node(
		(Select) {
			.options = options,
			.selected = selected,
			.width = width,
			.searchable = searchable,
			.on_change = on_change,
		}
	);
	ui.build(ui.@node((Stack) { }, elem));
	ui.flush();

	cui_tests::frame(ui, { width * 0.5f, 12 }, left: true);
	cui_tests::frame(ui, { width * 0.5f, 12 });
	ui.flush();
	return elem;
}

// Advance the frame loop, giving `update` hooks their ticks and rebuilding what
// they dirty. Search narrows across ticks — the field publishes what was typed,
// the list reads it — so a few of these settle a filter.
fn void settle(Ui* ui, Vec2 mouse, int n = 3) @local
{
	for (int i = 0; i < n; i++)
	{
		cui_tests::frame(ui, mouse);
		ui.flush();
	}
}

// Deliver typed text to the focused field, the way a platform reports a
// keystroke, and flush.
fn void type_text(Ui* ui, String text, Vec2 mouse) @local
{
	ui.process_input({ .mouse = mouse, .text = text }, 0.016f);
	ui.flush();
}

fn int option_count(Ui* ui) @local
{
	int n = 0;
	ui.@each(SelectOption ; e)
	{
		n++;
	};
	return n;
}

<*
 A list too tall for the screen rides a Scroll capped to the room around the
 head, instead of spilling off the bottom edge as the raw list once did.
*>
fn void a_long_list_scrolls_within_the_screen() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW); // {400, 100}
	defer ui.free();

	String[] opts = { "a", "b", "c", "d", "e", "f", "g", "h" }; // 8 * 26 = 208 tall
	open_select(ui, opts);

	Element* scroll_elem = ui.find(Scroll)!!;
	Scroll* scroll       = scroll_elem.widget_as(Scroll);

	test::@check(scroll_elem.size.y < cui_tests::WINDOW.y, "the list is capped to the screen (%f)", scroll_elem.size.y);
	test::@check(scroll.content_extent > scroll_elem.size.y, "and scrolls, its content overflowing the viewport");
	test::eq(option_count(ui), 8); // every option is emitted; the Scroll clips, not the build
}

<*
 A far-down current option is scrolled into view on open, not left above the top
 of a list that only shows its first rows.
*>
fn void the_current_option_opens_into_view() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	String[] opts = { "a", "b", "c", "d", "e", "f", "g", "h" };
	open_select(ui, opts, selected: 7);

	Scroll* scroll = ui.find(Scroll)!!.widget_as(Scroll);
	test::@check(scroll.scroll_offset > 0.0f, "the bound option is scrolled to, not left off-screen");
}

<*
 A plain Select carries no search field and shows every option.
*>
fn void a_plain_list_has_no_search_and_shows_all() @test
{
	Ui* ui = cui::new_ui({ 400, 400 });
	defer ui.free();

	String[] opts = { "Walk", "Run", "Jump" };
	open_select(ui, opts);

	test::eq(option_count(ui), 3);
	int searches = 0;
	ui.@each(SelectSearch ; e)
	{
		searches++;
	};
	test::eq(searches, 0);
}

<*
 A searchable list narrows to the options that match what was typed, folding
 case, and each surviving row keeps its index into the original list.
*>
fn void a_searchable_list_narrows_to_the_query() @test
{
	Ui* ui = cui::new_ui({ 400, 400 });
	defer ui.free();

	String[] opts = { "Walk", "Run", "Jump", "Idle", "RunFast" };
	open_select(ui, opts, searchable: true);
	settle(ui, { 80, 12 }, 2); // let the field take focus

	type_text(ui, "run", { 80, 12 });
	settle(ui, { 80, 12 });

	test::eq(option_count(ui), 2); // Run, RunFast — not Walk/Jump/Idle
	test::eq(ui.find_id("Run")!!.widget_as(SelectOption).index, (usz)1);
	test::eq(ui.find_id("RunFast")!!.widget_as(SelectOption).index, (usz)4);
}

<*
 A query that matches nothing shows the placeholder row rather than a blank
 panel, and no options.
*>
fn void an_unmatched_query_shows_the_placeholder() @test
{
	Ui* ui = cui::new_ui({ 400, 400 });
	defer ui.free();

	String[] opts = { "Walk", "Run", "Jump" };
	open_select(ui, opts, searchable: true);
	settle(ui, { 80, 12 }, 2);

	type_text(ui, "zzz", { 80, 12 });
	settle(ui, { 80, 12 });

	test::eq(option_count(ui), 0);
	int empties = 0;
	ui.@each(SelectEmpty ; e)
	{
		empties++;
	};
	test::eq(empties, 1);
}

<*
 Choosing a filtered option reports its index into the ORIGINAL list, not its
 position among the few that survived the filter.
*>
fn void choosing_a_filtered_option_reports_its_original_index() @test
{
	Ui* ui = cui::new_ui({ 400, 400 });
	defer ui.free();

	chosen_count = 0;
	chosen_index = 0;

	String[] opts = { "Walk", "Run", "Jump", "Idle", "RunFast" };
	open_select(ui, opts, searchable: true, on_change: &note_choice);
	settle(ui, { 80, 12 }, 2);

	type_text(ui, "fast", { 80, 12 }); // matches only RunFast, index 4
	settle(ui, { 80, 12 });
	test::eq(option_count(ui), 1);

	Element* row = ui.find_id("RunFast")!!;
	Vec2 at      = { row.absolute.x + row.size.x * 0.5f, row.absolute.y + row.size.y * 0.5f };
	cui_tests::frame(ui, at, left: true);
	cui_tests::frame(ui, at);

	test::eq(chosen_count, 1);
	test::eq(chosen_index, (usz)4);
}