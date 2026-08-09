// Dependency tracking: what `Element.watch` records, and which hooks
// `Ui.invalidate` re-runs because of it.
module cui_tests::watches;
import cui;
import cui_tests;
import std::core::test;

fn void invalidate_reruns_only_the_watchers() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	Steering steering = { .angle = 10.0 };
	ui.provide(&steering);

	int watcher_paints, bystander_paints;
	float seen;
	Element* watcher = ui.@node((WatchProbe){
		.pref = {30, 20},
		.paints = &watcher_paints,
		.reads_in_paint = true,
		.seen = &seen,
	});
	Element* bystander = ui.@node((WatchProbe){ .pref = {30, 20}, .paints = &bystander_paints });
	ui.build(ui.@node((Stack){}, ui.@node((Column){}, watcher, bystander)));

	ui.flush();
	test::eq(watcher_paints, 1);
	test::eq(bystander_paints, 1);
	test::eq(seen, 10.0f);

	steering.angle = 45.0;
	ui.invalidate(Steering);
	ui.flush();

	test::eq(watcher_paints, 2);
	test::eq(bystander_paints, 1); // re-emitted from its cache
	test::eq(seen, 45.0f);
}

fn void a_watch_is_recorded_once_however_often_the_hook_runs() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	Steering steering = { .angle = 10.0 };
	ui.provide(&steering);

	Element* watcher = ui.@node((WatchProbe){ .pref = {30, 20}, .reads_in_paint = true });
	ui.build(ui.@node((Stack){}, watcher));

	// The slots are a fixed-size array: a repaint that re-declared the same
	// dependency instead of replacing it would overflow after four frames.
	for (int i = 0; i < 8; i++)
	{
		watcher.request_paint();
		ui.flush();
		test::eq((int)watcher.watch_count, 1);
	}
}

fn void a_hook_that_stops_reading_stops_being_invalidated() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	Steering steering = { .angle = 10.0 };
	ui.provide(&steering);

	int paints;
	Element* watcher = ui.@node((WatchProbe){
		.pref = {30, 20},
		.paints = &paints,
		.reads_in_paint = true,
	});
	ui.build(ui.@node((Stack){}, watcher));
	ui.flush();
	test::eq(paints, 1);

	watcher.widget_as(WatchProbe).reads_in_paint = false;
	watcher.request_paint();
	ui.flush();
	test::eq(paints, 2);
	test::eq((int)watcher.watch_count, 0);

	ui.invalidate(Steering);
	ui.flush();
	test::eq(paints, 2);
}

fn void a_layout_watch_relayouts() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	Steering steering = { .angle = 10.0 };
	ui.provide(&steering);

	int layouts;
	Element* watcher = ui.@node((WatchProbe){
		.pref = {30, 20},
		.layouts = &layouts,
		.reads_in_layout = true,
	});
	ui.build(ui.@node((Stack){}, watcher));
	ui.flush();
	test::eq(layouts, 1);

	// The phase the value was read from is the phase that re-runs: a size that
	// depends on it has to be recomputed, not just redrawn.
	ui.invalidate(Steering);
	test::@check(watcher.dirty.layout);
	ui.flush();
	test::eq(layouts, 2);
}

fn void an_unwatched_type_invalidates_nothing() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	Steering steering = { .angle = 10.0 };
	ui.provide(&steering);

	int paints;
	Element* watcher = ui.@node((WatchProbe){
		.pref = {30, 20},
		.paints = &paints,
		.reads_in_paint = true,
	});
	ui.build(ui.@node((Stack){}, watcher));
	ui.flush();
	test::eq(paints, 1);

	ui.frame_requested = false; // the render loop consumed it

	// Never provided and never watched — a writer may call this unconditionally
	// without checking whether anything downstream cares.
	ui.invalidate(MountRecord);
	ui.flush();
	test::eq(paints, 1);
	test::@check(!ui.frame_requested);
}

fn void watching_outside_a_hook_is_only_inheriting() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	Steering steering = { .angle = 10.0 };
	ui.provide(&steering);

	Element* rect = ui.@node((Rectangle){ .size = {30, 20} });
	ui.build(ui.@node((Stack){}, rect));
	ui.flush();

	// Nothing is running, so there is no cached result to go stale and nothing
	// to attribute the read to. The value still comes back.
	Steering* got = rect.watch(Steering)!!;
	test::eq(got.angle, 10.0f);
	test::eq((int)rect.watch_count, 0);
}
