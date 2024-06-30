#[compute]
#version 450

#define EPS 0.000001

// Invocations in the (x, y, z) dimension
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D velocity_tex;
layout(rg8, set = 1, binding = 0) uniform restrict writeonly image2D tilemax_store;
layout(rg8, set = 2, binding = 0) uniform restrict writeonly image2D dbg_store;

// Our push PushConstant
layout(push_constant, std430) uniform Params {
	vec2 render_size;
	float frame_rate;
	float shutter_speed;
	float dilatate_radius_k;
} params;


float dist_sq(vec2 v ) {
    return dot( v, v );
}

vec2 velocity_convert(vec2 vel, float dilatate_radius_k, vec2 render_size, float frame_rate, float shutter_speed) {
	// case for FSR2 ?? not sure why might be a bug
	if(vel.x < -0.99 && vel.y < -0.99) return vec2(0,0);
	float min_texel = 1.0 /  max(render_size.x, render_size.y);
	float k_uv = dilatate_radius_k * min_texel;
	vec2 velocity = vel * frame_rate / shutter_speed;
	float max_vel_len = length(velocity);
	return  velocity * max(min_texel, min(k_uv, max_vel_len))  / (max_vel_len + EPS );
}


// The code we want to execute in each invocation
void main() {
	ivec2 render_size = ivec2(params.render_size.xy);
	int k_radius = int(params.dilatate_radius_k);
	ivec2 small_image_uv = ivec2(gl_GlobalInvocationID.xy);
	// We want to execute it each K samples on full res
	ivec2 image_uv = small_image_uv * k_radius;
	// Just in case the effect_size size is not divisable by 8
	if ((image_uv.x >= render_size.x) || (image_uv.y >= render_size.y)) {
		return;
	}
	vec2 max_vel = vec2(0,0);
	float max_length_sq = 0;
	//this will be replaced by two pass horizontal / vertical
	for(int x = 0; x<k_radius; ++x) {
		if (image_uv.x + x >= render_size.x) {
			break;
		}
		for(int y=0; y<k_radius; ++y) {
			if (image_uv.y + y >= render_size.y) {
				break;
			}
			//sample velocity
			vec2 uv = (vec2(image_uv) + vec2(x,y)) / params.render_size;
			vec2 velocity = textureLod(velocity_tex, uv, 0).xy;
			if(velocity.x < -0.99 && velocity.y < -0.99) continue; // FSR2.0 background separation?
			float len_sq = dist_sq(velocity);
			if(len_sq > max_length_sq){
				max_vel = velocity;
				max_length_sq = len_sq;
			}
		}
	}
	//now we want to rescale our velocity to 0..k range
	// in McGuire its defined a bit differently?

	//k is in pixels, but velicity in UV [0..1] space
	// rescale k
	//float k_uv = params.dilatate_radius_k / max(params.render_size.x, params.render_size.y);
	vec2 velocity = velocity_convert(max_vel, params.dilatate_radius_k, params.render_size.xy, params.frame_rate, params.shutter_speed);

	imageStore(tilemax_store, small_image_uv, vec4(velocity, 0,0));
	imageStore(dbg_store, small_image_uv, vec4(max_vel * params.frame_rate / params.shutter_speed, 0,0));
	

}