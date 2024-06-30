#[compute]
#version 450

#define EPS 0.000001

#define SAMPLE_TAPS_S 27

// Invocations in the (x, y, z) dimension
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform restrict writeonly image2D color_image;
layout(rgba16f, set = 1, binding = 0) uniform restrict readonly image2D texture_read;
//layout(set = 1, binding = 0) uniform sampler2D texture_tex; 
layout(set = 2, binding = 0) uniform sampler2D velocity_tex;
layout(set = 3, binding = 0) uniform sampler2D depth_tex;
layout(rg8, set = 4, binding = 0) uniform restrict readonly image2D neighbormax_read;
//layout(set = 4, binding = 0) uniform sampler2D neghbormax_tex;

// Our push PushConstant
layout(push_constant, std430) uniform Params {
	vec2 render_size;
	float frame_rate;
	float shutter_speed;
	float dilatate_radius_k;
} params;


//vec4 motion_blur(vec2 uv, float frame_rate, ivec2 effect_size, float shutter_speed)
//{
//	//deprecated
//	const int MAX_SAMPLES = 50;
//
//	vec2 texel_size = 1.0/vec2(effect_size);
//    vec2 velocity = -textureLod(velocity_tex, uv, 0).xy;
//	velocity *= frame_rate / shutter_speed;
//	float speed = length(velocity / texel_size);
//
//	int n_samples = clamp(int(speed), 1, MAX_SAMPLES);
//
//
//	vec4 result = textureLod(texture_tex, uv, 0.0);
//	float alpha = result.a;
//	for (int i = 1; i < n_samples; ++i) {
//		vec2 offset = velocity * (float(i) / float(n_samples - 1) - 0.5);
//		result += textureLod(texture_tex, uv + offset, 0);
//	}
//	result /= float(n_samples);
//	return vec4(result.rgb, alpha);
//	//float res =  float(n_samples)/float(MAX_SAMPLES);
//	//return vec4(res,res,res, 1.0);
//}



// Originally article was probably in linear depth?
// This function should modify it to work with log depth
// is zb closer than za?
//ex:
// za = fg obj = 0,00176
// zb = bg obj = 0,00146
//  = clamp(1.0 - (0,00146 - 0,00176) / SOFT_Z_EXTENT
//  = clamp(1.0 - (-0.0003) / SOFT_Z_EXTENT
// = clamp(1.0 - (-0.0003) /  0.001
// = -0.3
// clamp(-0.3) = 0 

//0.0017 - pot = za
//0.0013 - bg = zb
//zb > za =  false = 0
//1.0 - (zb - za) / SOFT_Z_EXTENT
//1.0 - (0.0013 - 0.0017)/ 0.0001
//1.0 - (13-17) = 1.0 - (-4)  === 4 WRONG

//


float soft_depth_compare(float za, float zb) {
	const float SOFT_Z_EXTENT = 0.0005;
	//return clamp(1.0 - (za - zb)/SOFT_Z_EXTENT, 0.0, 1.0);
	//return float(zb > za);
	return clamp(1.0 - (za - zb) / SOFT_Z_EXTENT, 0.0 , 1.0);
}


float cone(vec2 uv_a, vec2 uv_b, float v) {
    return clamp(1.0 - distance(uv_a, uv_b) / v, 0.0, 1.0);
}

float cone_l(float px_dist, float v) {
    return clamp(1.0 - px_dist / v, 0.0, 1.0);
}


float cylinder(vec2 uv_a, vec2 uv_b , float v) {
    return 1.0 - smoothstep(0.95 * v, 1.05 * v, distance(uv_a, uv_b));
}

float cylinder_l(float px_dist , float v) {
    return 1.0 - smoothstep(0.95 * v, 1.05 * v, px_dist);
}

//vec2 velocity_convert(vec2 vel, float dilatate_radius_k, vec2 render_size, float frame_rate, float shutter_speed) {
//	float min_texel = 1.0 /  max(render_size.x, render_size.y);
//	float k_uv = dilatate_radius_k * min_texel;
//	vec2 velocity = vel * frame_rate / shutter_speed;
//	float max_vel_len = length(velocity);
//	return  velocity * max(min_texel, min(k_uv, max_vel_len))  / (max_vel_len + EPS );
//}


vec3 velocity_convert_px(vec2 vel, float dilatate_radius_k, vec2 render_size, float frame_rate, float shutter_speed) {
	// case for FSR2 ?? not sure why might be a bug
	if(vel.x < -0.99 && vel.y < -0.99) return vec3(0,0,0.5);
	vec2 vel_raw = vel * frame_rate / shutter_speed;
	vec2 vel_px = vel_raw *  render_size;
	float vel_len = length(vel_px);
	float clamped_length = clamp(vel_len, 0.5, dilatate_radius_k);
	return  vec3(vel_px * clamped_length  / (vel_len + EPS ), clamped_length);// return clamped length to avoid INFs
}


vec2 tmp_calc_uv(int i, vec2 v_n, vec2 uv, vec2 texel_size, int sample_taps_s) {
	float jitter = 0.0;
	float t = ( float(i) + jitter + 1.0)/(sample_taps_s + 1.0) ;
	vec2 offset = v_n * (t +  texel_size * 0.5);
	return offset;
}

float rand(vec2 co){
    return fract(sin(dot(co, vec2(12.9898, 78.233))) * 43758.5453);
}

vec4 reconstruct(ivec2 coords, vec2 render_size, float radius_k, int sample_taps_s, float frame_rate, float shutter_speed) {
	// get largest velocity in neigborhood
	vec2 uv = vec2(coords) / render_size;
	vec2 v_n = imageLoad(neighbormax_read, coords/int(radius_k) ).xy;
	vec2 texel_size = vec2(1.0)/render_size;
	
	//return vec4(v_n,0,1);
	if( length(v_n) < EPS + texel_size.x * 0.5 ) {
		//return vec4(1,0,0,1);
		//return textureLod(texture_tex, uv, 0); // no blur needed
		return imageLoad(texture_read, coords); // no blur needed
	}

	//return vec4(v_n, 0.0, 1.0); 
	

	// current point sample
	vec2 vel_x_raw = textureLod(velocity_tex, uv, 0).xy;
	vec3 vel_x = velocity_convert_px(vel_x_raw, radius_k, render_size, frame_rate, shutter_speed);
	float len_vel_x = vel_x.z;
	

	float weight = 1.0/len_vel_x;
	vec4 sum = imageLoad(texture_read, coords) * weight;

	//return sum/weight;
	//TODO: add jitter
	float jitter = rand(vec2(coords)) - 0.5;

	float case_a_sum =0.0;
	float case_b_sum = 0.0;

	for(int i=0; i < sample_taps_s; ++i) {
		if(i == (sample_taps_s)/2) continue; // skip center
		// evenly placed filter taps along v_n
		float t = mix(-1.0, 1.0, (float(i) + jitter + 1.0)/(sample_taps_s + 1.0) );
		vec2 offset = v_n * (t +  texel_size * 0.5);
		vec2 uv_y = uv + offset;
		float offset_len_px = length(offset * render_size);

		// Fore- vs. background classification
		float depth_x = textureLod(depth_tex, uv, 0).x;
		float depth_y = textureLod(depth_tex, uv_y, 0).x;
		float f = soft_depth_compare(depth_x, depth_y);
		float b = soft_depth_compare(depth_y, depth_x);

		


		vec3 vel_y = velocity_convert_px(textureLod(velocity_tex, uv_y, 0).xy, radius_k, render_size, frame_rate, shutter_speed);
		float len_vel_y = vel_y.z;

		case_a_sum += f * cone_l(offset_len_px, len_vel_y);
		case_b_sum += b * cone_l(offset_len_px, len_vel_x);

		float ay = f * cone_l(offset_len_px, len_vel_y)  + // Case 1: Blurry Y in front of any X
				   b * cone_l(offset_len_px, len_vel_x) + // Case 2: Any Y behind blurry X; estimate background
				   cylinder_l(offset_len_px, len_vel_y) * cylinder_l(offset_len_px, len_vel_x) * 2.0;  // Case 3: Simultaneously blurry X and Y
		
		weight += ay;
		sum += ay * imageLoad(texture_read, ivec2(uv_y * render_size));
	}
	//return vec4(case_a_sum, case_b_sum, weight, 1.0);
	return sum/max(weight, EPS);
	//return vec4(weight, weight, weight, 1.0);
}

// The code we want to execute in each invocation
void main() {


	ivec2 render_size = ivec2(params.render_size.xy);

	ivec2 image_uv = ivec2(gl_GlobalInvocationID.xy);

	// Just in case the effect_size size is not divisable by 8
	if ((image_uv.x >= render_size.x) || (image_uv.y >= render_size.y)) {
		return;
	}

	// Get our depth
	vec2 uv = vec2(image_uv) / params.render_size;

	//vec4 color = motion_blur(uv, params.frame_rate, render_size, params.shutter_speed);
	vec4 color = reconstruct(image_uv, params.render_size.xy, params.dilatate_radius_k, SAMPLE_TAPS_S, params.frame_rate, params.shutter_speed);
	
	imageStore(color_image, image_uv, color);
}