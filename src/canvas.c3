module cui;
import std::io;
import std::collections::list;
import std::math;

const Matrix4f MATRIX4F_IDENTITY = { .m = { [0] = 1, [5] = 1, [10] = 1, [15] = 1 } };

struct Drawing {
    uint type;
    int texture_id;

    float border_width;

    Vec2 size;
    Vec2 corner;

    Vec4 border_radius;
    Vec4 color;
    Vec4 border_color;
    Matrix4f transform;
}