import std::io;
import cui;

fn void! main(String[] args)
{
	Renderer renderer = cui::new(.window_size = {900.0, 700.0})!;
	defer catch renderer.free();

	// renderer.draw(;window) {

	// }
	
}
