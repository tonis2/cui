<*
 Projection/view math for the uniform block of the cui shader. Vulkan-free, so
 embedding engines can reuse it to produce the exact matrices the shader expects
 (upload as-is — see `cui::ShaderUniforms` in shader.c3).

 The matrices come straight from `std::math::matrix`, so they carry its
 conventions: right-handed, [0, 1] depth (what Vulkan wants), and column-major
 storage — which is also the byte order the shader reads, hence no transpose
 anywhere. Use `math::deg_to_rad` for angles and `Matrix4f.rotate` /
 `matrix::ortho` if you need them; cui does not wrap what the standard library
 already has.
*>
module cui::camera;
import std::math;

<*
 An eye looking at a target. UI rendering uses it through `ui_view`, which
 makes canvas pixels map one-to-one to screen pixels.
*>
struct Camera
{
	Vec3 target;
	Vec3 eye;
	Matrix4f perspective;
	Matrix4f view;
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
fn Camera new(
	Vec3 target = { 0.0, 0.0, 0.0 },
	Vec3 eye = { 0.0, 0.0, 0.0 },
	float aspect = 0.8,
	float view = 45,
	float min_zoom = 0.1,
	float max_zoom = 500
)
{
	return {
		target,
		eye,
		matrix::perspective{float}(math::deg_to_rad(view), aspect, min_zoom, max_zoom),
		matrix::look_at{float}(eye, target, { 0.0, 1.0, 0.0 }),
	};
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
	float sx   = 2.0f / self.perspective.m00; // = 2 * aspect / f
	float sy   = 2.0f / self.perspective.m11; // = 2 / f
	Matrix4f v = self.view;
	v.m00 *= sx;
	v.m10 *= sx;
	v.m20 *= sx;
	v.m30 *= sx;
	v.m01 *= sy;
	v.m11 *= sy;
	v.m21 *= sy;
	v.m31 *= sy;
	return v;
}
