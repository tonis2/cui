<*
 Projection/view math for the uniform block of the cui shader. Vulkan-free, so
 embedding engines can reuse it to produce the exact matrices the shader expects
 (upload transposed — see `cui::ShaderUniforms` in shader.c3).
*>
module cui::camera;
import std::math;
import std::io;

<*
 Degrees to radians.

 @param value : `The angle in degrees.`
 @return `The angle in radians.`
*>
fn float radians(float value) {
    return value * (float)math::PI / 180;
}

<*
 The matrices a camera hands the shader, already transposed for upload.
*>
struct UniformData {
    Matrix4f projection;
    Matrix4f view;
    Vec3 eye;
}

<*
 An orbit camera: an eye looking at a target, with pitch/yaw and a zoom along the
 view axis. UI rendering uses it through `ui_view`, which makes canvas pixels map
 one-to-one to screen pixels.
*>
struct Camera {
    Vec3 target;
    Vec3 eye;
    Matrix4f perspective;
    Matrix4f view;
    float pitch;
    float yaw;
    float zoom_value;
}

<*
 Creates a camera with its perspective and view matrices built.

 @param target : `The point the camera looks at.`
 @param eye : `The camera position.`
 @param aspect : `Viewport aspect ratio (width / height).`
 @param view : `Vertical field of view, in degrees.`
 @param min_zoom : `Near plane distance.`
 @param max_zoom : `Far plane distance.`
 @return `The camera.`
*>
fn Camera new(Vec3 target = {0.0, 0.0, 0.0}, Vec3 eye = {0.0, 0.0, 0.0}, float aspect = 0.8, float view = 45, float min_zoom = 0.1, float max_zoom = 500) {
    return {
        target,
        eye,
        perspective(radians(view), aspect, min_zoom, max_zoom),
        matrix_look_at(eye, target, {0.0, 1.0, 0.0}),    
        0,
        0,
        -eye.z
    };
}

<*
 Orbits the eye around the target. Pitch is clamped to ±89° so the view never
 flips through the pole.

 @param x_offset : `Yaw change, in degrees.`
 @param y_offset : `Pitch change, in degrees.`
*>
fn void Camera.rotate (Camera* self, float x_offset, float y_offset) {
    self.yaw += x_offset;
    self.pitch += y_offset;

    if (self.pitch > 89.0) self.pitch = 89.0;
    if (self.pitch < -89.0) self.pitch = -89.0;

    self.eye = { math::cos(radians(self.yaw)) * math::cos(radians(self.pitch)),
                       math::sin(radians(self.pitch)),
                       math::sin(radians(self.yaw)) * math::cos(radians(self.pitch))};

    // if (x_offset != 0) self.eye = self.eye.rotate_axis({0, 1, 0}, x_offset * 0.1);
    // if (y_offset != 0) self.eye.y += y_offset * 0.5;

    // if (self.eye.y > 89.0) self.eye.y = 89.0;
    // if (self.eye.y < -89.0) self.eye.y = -89.0;

    self.view = matrix_look_at(self.eye, self.target, {0.0, 1.0, 0.0});
    self.view.m23 = self.zoom_value;
}

<*
 Moves the eye along the view axis. Ignored when it would push the camera through
 the target.

 @param value : `The zoom delta; negative moves closer.`
*>
fn void Camera.zoom(Camera* self, float value) {
    if (self.zoom_value + value > 0) return;
    self.zoom_value += value;
    self.view.m23 += value;
}

<*
 View matrix for UI rendering: the camera view with a compensating scale baked
 in, so canvas pixels land exactly on screen pixels.

 The raw perspective maps the unit z=0 plane to f/aspect (x) and f (y) in clip
 space instead of exactly 2.0, so drawings would land at ~94% / ~121% of their
 pixel coordinates. Scaling by 2/P[0][0] and 2/P[1][1] cancels that: canvas
 coordinates become pixel-exact while model transforms keep their perspective
 depth (w still varies once a transform rotates off the plane). The scale is
 composed innermost (applied before the camera transform), which in this storage
 means scaling the first two columns of the view.

 @return `The view matrix to upload for UI rendering.`
*>
fn Matrix4f Camera.ui_view(&self)
{
    float sx = 2.0f / self.perspective.m00;     // = 2 * aspect / f
    float sy = 2.0f / self.perspective.m11;     // = 2 / f
    Matrix4f v = self.view;
    v.m00 *= sx;
    v.m01 *= sx;
    v.m02 *= sx;
    v.m03 *= sx;
    v.m10 *= sy;
    v.m11 *= sy;
    v.m12 *= sy;
    v.m13 *= sy;
    return v;
}

<*
 The camera matrices, transposed and ready for `ShaderUniforms`.

 @return `Projection, view and eye position.`
*>
fn UniformData Camera.matrix(Camera self) {
    return {
        self.perspective.transpose(),
        self.view.transpose(),
        self.eye,
    };
}

<*
 A look-at view matrix.

 @param eye : `The camera position.`
 @param target : `The point to look at.`
 @param up : `The up axis.`
 @return `The view matrix.`
*>
fn Matrix4f matrix_look_at(Vec3 eye, Vec3 target, Vec3 up)
{
	Vec3 vz = (eye - target).normalize();
	Vec3 vx = up.cross(vz).normalize();
	Vec3 vy = vz.cross(vx);

	return {
		vx[0], vx[1], vx[2], - vx.dot(eye),
		vy[0], vy[1], vy[2], - vy.dot(eye),
		vz[0], vz[1], vz[2], - vz.dot(eye),
		0.0, 0.0, 0.0, 1
	};
}

<*
 A perspective projection matrix.

 @param fov : `Vertical field of view, in radians.`
 @param aspect_ratio : `Viewport width / height.`
 @param near : `Near plane distance.`
 @param far : `Far plane distance.`
 @return `The projection matrix.`
*>
fn Matrix4f perspective(float fov, float aspect_ratio, float near, float far)
{
	float f = (float)math::tan(math::PI * 0.5 - 0.5 * fov);
	float rangeInv = (float)1.0 / (near - far);

	return {
		f / aspect_ratio, 0, 0, 0,
		0, f, 0, 0,
		0, 0, (near + far) * rangeInv,  near * far * rangeInv * 2,
		0, 0, -1, 0,
	};
}


<*
 An orthographic projection matrix.

 @param left : `Left plane.`
 @param right : `Right plane.`
 @param bottom : `Bottom plane.`
 @param top : `Top plane.`
 @param near : `Near plane.`
 @param far : `Far plane.`
 @return `The projection matrix.`
*>
fn Matrix4f ortho(float left, float right, float bottom, float top, float near, float far)
{
    float width = right - left;
    float height = top - bottom;
    float depth = far - near;

    float x = right + left;
    float y = top + bottom;
    float z = far + near;

	return {
		2 / width, 0, 0, x / width,
		0, 2 / height, 0, height / y,
		0, 0, 1 / depth, near / (near - far),
		0, 0, 0, 1
	};
}


<*
 A rotation matrix around an arbitrary axis.

 @param axis : `The axis to rotate around; normalized internally.`
 @param angle : `The rotation, in degrees.`
 @return `The rotation matrix.`
*>
fn Matrix4f matrixRotation(Vec3 axis, float angle)
{
    Vec3 norm_axis = axis.normalize();

    float sin = math::sin(radians(angle));
    float cos = math::cos(radians(angle));
    float cosi = 1 - cos;

    float x = norm_axis.x;
    float y = norm_axis.y;
    float z = norm_axis.z;

    float cx = cosi * x;
    float cy = cosi * y;
    float cz = cosi * z;

    return {
        cx * x + cos, cx * y + z * sin, cz * x - y * sin, 0.0,
        cx * y - z  * sin, cy * y + cos, cy * z + x * sin, 0.0,
        cz * x + y * sin, cy * z - x * sin, cz * z + cos, 0.0,
        0.0, 0.0, 0.0, 1.0
    };
}
