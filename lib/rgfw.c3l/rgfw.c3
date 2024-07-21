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

def RG_Window = void*;

struct Rect {
    int x,y,w,h;
}

struct Vec2 {
    int x,y;
}

struct Area {
    int w,h;
}

const MAX_DROPS = 260;

struct RGFW_Event {
    char[16] keyName;
	char* droppedFiles;
	uint droppedFilesCount; 
	uint type;
	Vec2 point;
	uint fps;
	long frameTime, frameTime2;
	char keyCode;
	char inFocus;
	char lockState;
	short joystick; 
	char button;
	double scroll;
	char axisesCount;
	Vec2[2] axis;
}

struct DarwinWindow {
	uint display;
    void* displayLink;
    void* window;
    char dndPassed;
    void* ctx; 
    void* view; 

    void* bitmap;
    void* image;
}

struct LinuxWindow {
  	void* display;
    void* window;
    void* ctx;
    void* bitmap;
    void* gc;
}

struct Window {
    DarwinWindow src @if(env::os_is_darwin());
	LinuxWindow src @if(env::LINUX);
	char* buffer;
    RGFW_Event event;
    Rect rect;
    uint fps_cap;
    uint args;
}

extern fn Window createWindow(char* name, Rect rect, ushort args) @extern("RGFW_createWindow");

    // keyName : [16]byte, /*!< key name of event */
    // /*! drag and drop data */
    // /* 260 max paths with a max length of 260 */
    // droppedFiles : [MAX_DROPS][MAX_PATH]byte,
    // droppedFilesCount : u32, /*!< house many files were dropped */

    // type : event_codes, /*!< which event has been sent?*/
    // point : vector, /*!< mouse x, y of event (or drop point) */
    
    // fps : u32, /*the current fps of the window [the fps is checked when events are checked]*/
    // frameTime : u64, 
    // frameTime2 : u64,

    // keyCode : Key,  /*!< keycode of event 	!!Keycodes defined at the bottom of the header file!! */

    // inFocus : b8,  /*if the window is in focus or not*/

    // lockState : lockStates,

    // joystick : u16, /* which joystick this event applies to (if applicable to any) */

    // button : u8, /*!< which mouse button has been clicked (0) left (1) middle (2) right OR which joystick button was pressed*/
    // scroll : f64, /* the raw mouse scroll value */

    // axisesCount : u8, /* number of axises */
    // axis : [2]vector /* x, y of axises (-100 to 100) */