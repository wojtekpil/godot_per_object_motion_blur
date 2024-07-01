#[versions]
default = "";
correct_velocity = "#define APPLY_VELOCITY_CORRECTION";

#[compute]
#version 450

#VERSION_DEFINES

#define EPS 0.000001

// Invocations in the (x, y, z) dimension
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D velocity_tex;
layout(rg8, set = 1, binding = 0) uniform restrict writeonly image2D tilemax_store;

// Our push PushConstant
layout(push_constant, std430) uniform Params {
	vec2 render_size;
	float frame_rate;
	float shutter_speed;
	float dilatate_radius_k;
} params;


vec2 velocity_convert(vec2 vel, float dilatate_radius_k, vec2 render_size, float frame_rate, float shutter_speed) {
	// case for FSR2 ?? not sure why might be a bug
	if(vel.x < -0.99 && vel.y < -0.99) return vec2(0,0);
	float min_texel = 1.0 /  max(render_size.x, render_size.y);
	float k_uv = dilatate_radius_k * min_texel;
	vec2 velocity = vel * frame_rate / shutter_speed;
	float max_vel_len = length(velocity);
	return  velocity * max(min_texel, min(k_uv, max_vel_len))  / (max_vel_len + EPS );
}

void main() {
	ivec2 render_size = ivec2(params.render_size.xy);
	int k_radius = int(params.dilatate_radius_k);
	ivec2 small_image_coords = ivec2(gl_GlobalInvocationID.xy);
	// We want to execute it each K samples on full res each axis at time.
	// We use transpose trick the axis so after two iterations we have original image
	ivec2 image_coords = ivec2(small_image_coords.y * k_radius, small_image_coords.x);
	// Just in case
	if ((image_coords.x >= render_size.x) || (image_coords.y >= render_size.y)) {
		return;
	}


	vec2 max_vel = vec2(0,0);
	float max_length_sq = 0;
	for(int x=0; x<k_radius; ++x) {
		//sample velocity
		ivec2 coords = image_coords + ivec2(x,0);
		vec2 velocity = texelFetch(velocity_tex, coords, 0).xy;
		if(velocity.x < -0.999 && velocity.y < -0.999) continue; // FSR2.0 background separation? Ignore those values
		float len_sq = dot(velocity, velocity);
		if(len_sq > max_length_sq){
			max_vel = velocity;
			max_length_sq = len_sq;
		}
	}
#ifdef APPLY_VELOCITY_CORRECTION
	//now we want to rescale our velocity to 0..k range
	//in McGuire its defined a bit differently?
	//k is in pixels, but Godot velicity in UV [0..1] space
	// rescale k
	vec2 velocity = velocity_convert(max_vel, params.dilatate_radius_k, params.render_size.xy, params.frame_rate, params.shutter_speed);
#else
	vec2 velocity = max_vel;
#endif
	imageStore(tilemax_store, small_image_coords, vec4(velocity, 0,0));
}