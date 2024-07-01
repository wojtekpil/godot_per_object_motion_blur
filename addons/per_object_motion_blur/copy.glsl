#[compute]
#version 450

// Invocations in the (x, y, z) dimension
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform restrict readonly image2D  color_tex;
layout(rgba16f, set = 1, binding = 0) uniform restrict writeonly image2D texture_store;

// Our push PushConstant
layout(push_constant, std430) uniform Params {
	vec2 render_size;
	float frame_rate;
	float shutter_speed;
	float dilatate_radius_k;
} params;

// The code we want to execute in each invocation
void main() {
	ivec2 render_size = ivec2(params.render_size.xy);

	ivec2 image_coords = ivec2(gl_GlobalInvocationID.xy);
	// Just in case the effect_size size is not divisable by 8
	if ((image_coords.x >= render_size.x) || (image_coords.y >= render_size.y)) {
		return;
	}

	vec4 img_sampled = imageLoad(color_tex, image_coords);
	
	imageStore(texture_store, image_coords, img_sampled);
}