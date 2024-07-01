module cui;
import std::io;
import std::collections::list;
import std::math;


struct Drawing {
    uint type;
    int texture_id;

    float border_width;

    Vec2f size;
    Vec2f corner;

    Vec4f border_radius;
    Vec4f color;
    Vec4f border_color;
    Matrix4f transform;
}