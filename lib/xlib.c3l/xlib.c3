

def Screen = void*;
def Window = void*;
def Display = void*;

struct Attributes {	
    int x, y;
    int width; 
    int height;
}

extern fn void initThreads() @extern("XInitThreads");
extern fn Screen openDisplay(char* name = null) @extern("XOpenDisplay");
extern fn void getAttributes(Display display, Window window, Attributes* attributes) @extern("XGetWindowAttributes");
extern fn Screen defaultScreen(Display display) @extern("DefaultScreenOfDisplay");