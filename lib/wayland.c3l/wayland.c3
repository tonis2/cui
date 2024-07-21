module wlnd;

def Screen = void*;
def Window = void*;
def Display = void*;


extern fn Display openDisplay(char* name = null) @extern("wl_display_connect");
extern fn void disconnectDisplay(Display display) @extern("wl_display_disconnect");