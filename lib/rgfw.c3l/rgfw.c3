module rgfw;
import std::math;

const TRANSPARENT_WINDOW = (1L<<9);
const NO_BORDER = (1L<<3);
const NO_RESIZE = (1L<<4);
const ALLOW_DND = (1L<<5);
const HIDE_MOUSE = (1L<<6);
const FULLSCREEN = (1L<<8);

const CENTER = (1L<<10);
const OPENGL_SOFTWARE = (1L<<11);
const COCOA_MOVE_TO_RESOURCE_DIR = (1L<<12);

const SCALE_TO_MONITOR = (1L<<13);
const NO_INIT_API = (1L<<2);
const NO_GPU_RENDER = (1L<<14);
const NO_CPU_RENDER = (1L<<15);

const KEY_PRESSED = 2;
const KEY_RELEASED = 3;

const MOUSE_PRESSED = 4;
const MOUSE_RELEASED = 5;
const MOUSE_POS_CHANGED = 6;

const QUIT = 33;
const DND = 34;
const DND_INIT = 35;

const LEFT_MOUSE = 1;
const RIGHT_MOUSE = 2;
const MIDDLE_MOUSE = 3;
const MOUSE_SCROLL_UP = 4;
const MOUSE_SCROLL_DOWN = 5;


struct RGFW_Event {
    char[16] keyName; 
	uint droppedFilesCount; 
	uint type;
	Vec2f point;
	uint fps;
	long frameTime, frameTime2;
	char keyCode;
	char inFocus;
	char lockState;
	short joystick; 
	char button;
	double scroll;
	char axisesCount;
}

struct WindowSrc {
    void* display @if(env::LINUX);
    void* window @if(env::LINUX);

    void* window @if(env::WIN32); //HWND
	void* hdc @if(env::WIN32);
	uint hOffset @if(env::WIN32);

    uint display @if(env::os_is_darwin());
	void* displayLink @if(env::os_is_darwin());
	void* window @if(env::os_is_darwin());
	char dndPassed @if(env::os_is_darwin());
}

struct Window {
    WindowSrc src;
    RGFW_Event event;
    Rect rect;
    uint fps_cap;
    uint args;
}

struct Rect {
    int x,y,w,h;
}

extern fn Window createWindow(char* name, Rect rect, ushort args) @extern("RGFW_createWindow");