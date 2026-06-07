module cui;
import std::io;
import std::collections::list;
import std::math;

typedef Color = Vec4;

const Color WHITE = {1.0, 1.0, 1.0, 1.0}; // 255;
const Color BLACK = {0.0, 0.0, 0.0, 1.0};
const Color BLUE = {0.5, 0.5, 0.5, 1.0};

interface Widget
{
    // fn Vec2 layout(Vec2 constraint);
    fn Widget build(BuildContext context) @optional;
    fn void paint(Vec2 corner, Vec2 size, CanvasContext* canvas) @optional;
}

struct CanvasContext {
    Vec2 size;
    List{Widget} widgets;
    List{BuildContext} context;
    List{Drawing} drawings;
    Widget body;
}

fn void CanvasContext.free(&self)
{
   self.widgets.free();
   self.context.free();
   self.drawings.free();
}

fn void CanvasContext.draw(&self, Drawing value)
{
   self.drawings.push(value);
}

fn void CanvasContext.update(&self)
{
    foreach (Widget widget : self.widgets) {
        if (&widget.paint)
        {
            
        }
    }
}

fn List{Widget} widgets(Widget[] items)
{
    List{Widget} response;
    response.init_wrapping_array(mem, items);
    return response;
}

struct BuildContext {
    usz id;
    usz parent_id;
    bool dirty;
    Vec2 constraints;
    Vec2 corner;
}

// struct Container {
//     Vec2 size;
//     Vec4 color;
// }

struct Rectangle (Widget) {
    usz id;
    float width;
    float height;
    Vec2 pos;
    Color color;
}

fn void Rectangle.paint(&self, Vec2 corner, Vec2 size, CanvasContext* canvas) @dynamic
{   
    canvas.draw(
        {
            .corner = self.pos,
            .size = {self.width, self.height},
            .color = (Vec4)self.color,
            .transform = MATRIX4F_IDENTITY,
        }
    );
}

// fn Widget Container.build(BuildContext context) @dynamic
// {
//     return "I am int!";
// }


struct Column (Widget) {
    List{Widget} children;
    float width;
    float height;
    Vec2 pos;
}

fn void Column.paint(&self, Vec2 corner, Vec2 size, CanvasContext* canvas) @dynamic
{
    // return Drawing {
    //     .corner = self.pos,
    //     .size = {self.width, self.height},
    //     .color = (Vec4)self.color,
    //     .transform = MATRIX4F_IDENTITY,
    // };
}



