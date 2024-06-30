#[compute]
#version 450

#define EPS 0.000001

// Invocations in the (x, y, z) dimension
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rg8, set = 1, binding = 0) uniform restrict readonly image2D tilemax_read;
layout(rg8, set = 2, binding = 0) uniform restrict writeonly image2D neighbormax_store;

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


// The code we want to execute in each invocation
void main() {
	ivec2 render_size = ivec2(params.render_size.xy);
	int k_radius = int(params.dilatate_radius_k);
	ivec2 image_uv = ivec2(gl_GlobalInvocationID.xy);

	ivec2 texture_size = render_size/k_radius;
	
	// Just in case the effect_size size is not divisable by 8
	if ((image_uv.x >= texture_size.x) || (image_uv.y >= texture_size.y)) {
		return;
	}
	vec2 max_vel = vec2(0,0);
	float max_length_sq = 0;
	for(int x = -1; x <=1; ++x) {

		for(int y=-1; y<=1; ++y) {
			ivec2 texel = image_uv + ivec2(x,y);
			if (texel.x < 0 || texel.y < 0 || texel.x >= texture_size.x || texel.y >= texture_size.y) {
				continue;
			}

			vec2 velocity = imageLoad(tilemax_read, texel).xy;
			float len_sq = dist_sq(velocity);
			if(len_sq > max_length_sq){
				max_vel = velocity;
				max_length_sq = len_sq;
			}
		}
	}


	imageStore(neighbormax_store, image_uv, vec4(max_vel, 0,0));
	

}