// FileBrowser's look: an icon for each kind of row, a long name cut short of the
// size column, and a note in an empty folder. Each test lists a scratch folder
// it makes under build/ and removes again.
module cui_tests::file_browser;
import cui;
import cui::widgets;
import cui_tests;
import std::core::test;
import std::core::string;
import std::io;
import std::io::file;
import std::io::path;
import std::math;

const String FONT @local = "test/assets/DejaVuSans.ttf";
const float WIDTH @local = 320.0;
const String LONG_NAME @local = "a_model_name_long_enough_to_run_into_the_size_column_on_any_sane_width.glb";

// A fresh, empty scratch folder; the caller fills it.
fn String scratch(String name) @local
{
	String dir = string::tformat("build/file_browser_test/%s", name);
	(void)path::rmtree((Path)dir);
	path::mkdir((Path)dir, recursive: true)!!;
	return dir;
}

fn void put(String dir, String name, sz bytes = 10) @local
{
	char[] body = mem::new_array(char, bytes);
	defer free(body);
	file::save(string::tformat("%s/%s", dir, name), body)!!;
}

fn Ui* browsing(String dir, String[] mask = {}) @local
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	ui.load_font(FONT)!!;
	ui.build(ui.@node((Column) { .size = { WIDTH, 0 } }, ui.@node((FileBrowser) { .start = dir, .mask = mask })));
	ui.flush();
	return ui;
}

fn Element* browser_of(Ui* ui) @local => ui.find(FileBrowser)!!;

// Whether anything other than text is drawn in the icon slot of `row`.
fn bool has_icon(Element* elem, int row, DrawingKind kind) @local
{
	FileBrowserStyle style = widgets::DEFAULT_FILE_BROWSER_STYLE;
	float top = (float)row * style.row_height;
	float slot = style.padding + style.icon_size + 2.0f;
	foreach (d : elem.local_drawings.array_view())
	{
		if (d.kind != kind) continue;
		float mid = d.corner.y + d.size.y * 0.5f;
		if (d.corner.x < slot && d.corner.x + d.size.x > style.padding - 2.0f && mid > top && mid < top + style.row_height) return true;
	}
	return false;
}

fn void folders_files_and_the_parent_each_get_an_icon() @test
{
	String dir = scratch("icons");
	defer (void)path::rmtree((Path)dir);
	path::mkdir((Path)string::tformat("%s/models", dir))!!;
	put(dir, "goat.glb");

	Ui* ui = browsing(dir);
	defer ui.free();
	Element* elem = browser_of(ui);
	FileBrowser* browser = elem.widget_as(FileBrowser);

	test::eq(browser.rows(), (usz)3);
	test::@check(has_icon(elem, 0, DrawingKind.LINE), "the parent row has no arrow");
	test::@check(has_icon(elem, 1, DrawingKind.RECT), "the folder row has no folder");
	test::@check(has_icon(elem, 2, DrawingKind.LINE), "the file row has no page");
	test::@check(!has_icon(elem, 1, DrawingKind.LINE), "the folder drew a page");
}

fn void a_long_name_stops_short_of_the_size_column() @test
{
	String dir = scratch("long");
	defer (void)path::rmtree((Path)dir);
	put(dir, LONG_NAME, 2048);

	Ui* ui = browsing(dir);
	defer ui.free();
	Element* elem = browser_of(ui);
	FileBrowserStyle style = widgets::DEFAULT_FILE_BROWSER_STYLE;

	// The row's glyphs left to right: a name cut short of the size column leaves
	// a clear gap before it, and one that ran on would leave none.
	float[256] lefts;
	float[256] rights;
	usz count;
	foreach (d : elem.local_drawings.array_view())
	{
		if (d.kind != DrawingKind.GLYPH || d.corner.y < style.row_height * 0.5f) continue;
		if (count == lefts.len) break;
		usz at = count++;
		while (at > 0 && lefts[at - 1] > d.corner.x)
		{
			lefts[at] = lefts[at - 1];
			rights[at] = rights[at - 1];
			at--;
		}
		lefts[at] = d.corner.x;
		rights[at] = d.corner.x + d.size.x;
	}
	test::@check(count > 4 && count < LONG_NAME.len, "drew %d glyphs for a %d-byte name", count, LONG_NAME.len);
	float reach = rights[0];
	float gap = 0;
	for (usz i = 1; i < count; i++)
	{
		gap = math::max(gap, lefts[i] - reach);
		reach = math::max(reach, rights[i]);
	}
	test::@check(gap >= 8.0f, "the name ran into the size column (widest gap %f)", gap);
	test::@check(reach <= WIDTH, "the size ran out of the row to %f", reach);
}

fn void an_empty_folder_says_so_under_its_parent_row() @test
{
	String dir = scratch("empty");
	defer (void)path::rmtree((Path)dir);

	Ui* ui = browsing(dir);
	defer ui.free();
	Element* elem = browser_of(ui);
	FileBrowserStyle style = widgets::DEFAULT_FILE_BROWSER_STYLE;

	test::eq(elem.widget_as(FileBrowser).rows(), (usz)1);
	test::@check(elem.size.y > style.row_height * 2.0f, "no room was left for the note: %f", elem.size.y);
	bool below;
	foreach (d : elem.local_drawings.array_view())
	{
		below = below || (d.kind == DrawingKind.GLYPH && d.corner.y > style.row_height);
	}
	test::@check(below, "nothing was written in the empty folder");
}

fn void a_filtered_out_file_leaves_the_folder_looking_empty() @test
{
	String dir = scratch("filtered");
	defer (void)path::rmtree((Path)dir);
	put(dir, "notes.txt");

	String[1] mask = { "*.glb" };
	Ui* ui = browsing(dir, mask[..]);
	defer ui.free();

	test::eq(browser_of(ui).widget_as(FileBrowser).rows(), (usz)1);
	test::@check(browser_of(ui).size.y > widgets::DEFAULT_FILE_BROWSER_STYLE.row_height * 2.0f, "no note under a filtered listing");
}
