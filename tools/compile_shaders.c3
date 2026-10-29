// Compiles src/shaders/shader.shady into the src/shaders/shader.spv that
// render/shader.c3 embeds. Run it from the repository root after editing the
// shader:
//
//   c3c run shaders
//
// shady (https://github.com/tonis2/shady.c3) compiles in-process, so this needs
// no external toolchain - only lib/shady.c3l. Scalar layout makes the shader's
// blocks match cui's C3 structs byte for byte.
import std::io;
import std::io::file;
import shady;

const String SOURCE = "src/shaders/shader.shady";
const String OUTPUT = "src/shaders/shader.spv";

fn int main(String[] args)
{
	char[]? source = file::load(mem, SOURCE);
	if (catch source)
	{
		io::eprintfn("shaders: cannot read %s", SOURCE);
		return 1;
	}
	defer free(source);

	shady::Diagnostic diagnostic;
	shady::DiagnosticList warnings;
	warnings.init(mem, 4);
	defer
	{
		foreach (warning : warnings) warning.free();
		warnings.free();
	}

	char[]? spirv = shady::compile((String)source, &diagnostic, scalar_layout: true, warnings: &warnings);
	foreach (warning : warnings) io::eprintfn("%s", warning.render(tmem));
	if (catch spirv)
	{
		io::eprintfn("%s", diagnostic.render(tmem));
		diagnostic.free();
		return 1;
	}
	diagnostic.free();
	defer free(spirv);

	if (catch file::save(OUTPUT, spirv))
	{
		io::eprintfn("shaders: cannot write %s", OUTPUT);
		return 1;
	}
	io::printfn("shaders: %s -> %s (%d bytes)", SOURCE, OUTPUT, spirv.len);
	return 0;
}
