#[compute]
#version 450

#define EPS 0.000001

#define SAMPLE_TAPS_S 15

//#define USE_LOCAL_VEL

#ifdef USE_LOCAL_VEL
#define MOVING_THRESHOLD_PX 1.5 // values smaller than that will use neighbor direction
#endif
// Invocations in the (x, y, z) dimension
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform restrict writeonly image2D color_image;
layout(rgba16f, set = 1, binding = 0) uniform restrict readonly image2D texture_read;
layout(set = 2, binding = 0) uniform sampler2D velocity_tex;
layout(set = 3, binding = 0) uniform sampler2D depth_tex;
layout(rg8, set = 4, binding = 0) uniform restrict readonly image2D neighbormax_read;


// Our push PushConstant
layout(push_constant, std430) uniform Params {
	vec2 render_size;
	float frame_rate;
	float shutter_speed;
	float dilatate_radius_k;
} params;

// Originally article was probably in linear depth?
// This function should modify it to work with raw depth
// is zb closer than za?
//ex:
// SOFT_Z_EXTENT =  0.001
// za = fg obj = 0,00176
// zb = bg obj = 0,00146
//  = 1.0 - (0,00146 - 0,00176) / SOFT_Z_EXTENT
//  = 1.0 - (-0.0003) / SOFT_Z_EXTENT
// = 1.0 - (-0.0003) /  0.001
// = 1.0 - (-0.3)
// clamp(1.3, 0, 1) = 1 
float soft_depth_compare(float za, float zb) {
	const float SOFT_Z_EXTENT = 0.0005; //empirical value. This will not be stable over all object distances, since we are in log space
	return clamp(1.0 - (za - zb) / SOFT_Z_EXTENT, 0.0 , 1.0);
}

float cone_l(float px_dist, float v) {
    return clamp(1.0 - px_dist / v, 0.0, 1.0);
}

float cylinder_l(float px_dist , float v) {
    return 1.0 - smoothstep(0.95 * v, 1.05 * v, px_dist);
}



vec3 velocity_convert_px(vec2 vel, float dilatate_radius_k, vec2 render_size, float frame_rate, float shutter_speed) {
	// case for FSR2 ?? not sure why might be a bug
	if(vel.x < -0.99 && vel.y < -0.99) return vec3(0,0,0.5);
	vec2 vel_raw = vel * frame_rate / shutter_speed;
	vec2 vel_px = vel_raw *  render_size;
	float vel_len = length(vel_px);
	float clamped_length = clamp(vel_len, 0.5, dilatate_radius_k);
	return  vec3(vel_px * clamped_length  / (vel_len + EPS ), clamped_length);// return clamped length to avoid INFs
}

float rand(vec2 co){
    return fract(sin(dot(co, vec2(12.9898, 78.233))) * 43758.5453);
}

vec4 reconstruct(ivec2 coords, vec2 render_size, float radius_k, int sample_taps_s, float frame_rate, float shutter_speed) {
	// get largest velocity in neigborhood
	vec2 uv = vec2(coords) / render_size;
	vec2 v_n = imageLoad(neighbormax_read, coords/int(radius_k) ).xy;
	vec2 texel_size = vec2(1.0)/render_size;
	float v_n_len = length(v_n);
	
	//return vec4(v_n,0,1);
	if( v_n_len < EPS + texel_size.x * 0.5 ) {
		return imageLoad(texture_read, coords); // no blur needed
	}

	// current point sample
	vec2 vel_x_raw = textureLod(velocity_tex, uv, 0).xy;
	vec3 vel_x = velocity_convert_px(vel_x_raw, radius_k, render_size, frame_rate, shutter_speed);
	float len_vel_x = vel_x.z;

	float weight = 1.0/len_vel_x;
	vec4 sum = imageLoad(texture_read, coords) * weight;

	//return sum/weight;
	float jitter = (rand(vec2(coords)) - 0.5)*0.5;
	//jitter = 0.0;

	//float case_a_sum =0.0;
	//float case_b_sum = 0.0;

#ifdef USE_LOCAL_VEL
	// This line below is an improvement to algirithm? Hopefully xD
	// Idea is to use neighbor velocity for taps only if velocity in current pixel is below very low threshold. 
	// Otherwise we will use its own velocity direction, was looking weird with len_vel_x though
	vec2 blur_vel = (len_vel_x < MOVING_THRESHOLD_PX) ? v_n: normalize(vel_x.xy * texel_size) * v_n_len; // vel_x is in px, but v_n is uv space. Those two will give different angle without conversion
#else
	vec2 blur_vel = v_n; 
#endif

	for(int i=0; i < sample_taps_s; ++i) {
		if(i == (sample_taps_s)/2) continue; // skip center
		// evenly placed filter taps along blur_vel
		float t = mix(-1.0, 1.0, (float(i) + jitter + 1.0)/(sample_taps_s + 1.0) );
		vec2 offset = blur_vel * (t +  texel_size * 0.5);
		vec2 uv_y = uv + offset;
		float offset_len_px = length(offset * render_size);

		// Fore- vs. background classification
		float depth_x = textureLod(depth_tex, uv, 0).x;
		float depth_y = textureLod(depth_tex, uv_y, 0).x;
		float f = soft_depth_compare(depth_x, depth_y);
		float b = soft_depth_compare(depth_y, depth_x);

		vec3 vel_y = velocity_convert_px(textureLod(velocity_tex, uv_y, 0).xy, radius_k, render_size, frame_rate, shutter_speed);
		float len_vel_y = vel_y.z;

		//case_a_sum += f * cone_l(offset_len_px, len_vel_y);
		//case_b_sum += b * cone_l(offset_len_px, len_vel_x);
		float ay = f * cone_l(offset_len_px, len_vel_y)  + // Case 1: Blurry Y in front of any X
				   b * cone_l(offset_len_px, len_vel_x) + // Case 2: Any Y behind blurry X; estimate background
				   cylinder_l(offset_len_px, len_vel_y) * cylinder_l(offset_len_px, len_vel_x) * 2.0;  // Case 3: Simultaneously blurry X and Y
		
		weight += ay;
		sum += ay * imageLoad(texture_read, ivec2(uv_y * render_size));
	}
	//return vec4(case_a_sum, case_b_sum, weight, 1.0);
	return sum/max(weight, EPS);
}


void main() {

	ivec2 render_size = ivec2(params.render_size.xy);
	ivec2 image_uv = ivec2(gl_GlobalInvocationID.xy);
	// Just in case the effect_size size is not divisable by 8
	if ((image_uv.x >= render_size.x) || (image_uv.y >= render_size.y)) {
		return;
	}

	vec4 color = reconstruct(image_uv, params.render_size.xy, params.dilatate_radius_k, SAMPLE_TAPS_S, params.frame_rate, params.shutter_speed);
	
	imageStore(color_image, image_uv, color);
}