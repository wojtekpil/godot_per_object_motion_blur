@tool
extends CompositorEffect
class_name PerObjectMotionBlur

# Based on: http://john-chapman-graphics.blogspot.com/2013/01/per-object-motion-blur.html
# Based on: https://github.com/BastiaanOlij/RERadialSunRays/blob/master/radial_sky_rays/radial_sky_rays.gd

## Shutter speed in Hz. Lower values will result in bluerrier image during movement
## Some implementations suggests to use a % value of actuall frame rate.
## On the other hand I decided to use a constant target value to achieve similar results independent of current frame rate.
@export_range(1, 240.0) var shutter_speed_hz : float = 60

@export_group("Advance", "dilatation_")

## Blur radius `k` as "fraction" of dominant screen axis size. E.g 0.1 with 1920x1080px will result in 192px of maximum blur on screen
@export var blur_radius: float = 0.1

var rd : RenderingDevice
var copy_shader : RID ## DEPRECATED
var copy_pipeline : RID ## DEPRECATED

var tilemax_shader : RID
var tilemax_pipeline : RID

var neighbormax_shader: RID
var neighbormax_pipeline: RID


var shader : RID
var pipeline : RID

var nearest_sampler : RID
var linear_sampler : RID


var context : StringName = "PerObjectMotionBlur"
var texture : StringName = "texture"
var texture_tilemax : StringName = "texture_tilemax"
var texture_neighbormax : StringName = "texture_neighbormax"


func _init():
	effect_callback_type = CompositorEffect.EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	needs_motion_vectors = true
	rd = RenderingServer.get_rendering_device()
	if !rd:
		return
	RenderingServer.call_on_render_thread(_initialize_compute)


func _notification(what):
	if what == NOTIFICATION_PREDELETE:
		# When this is called it should be safe to clean up our shader.
		# If not we'll crash anyway because we can no longer call our _render_callback.
		if nearest_sampler.is_valid():
			rd.free_rid(nearest_sampler)
		if linear_sampler.is_valid():
			rd.free_rid(linear_sampler)
		if shader.is_valid():
			rd.free_rid(shader)
		if copy_shader.is_valid():
			rd.free_rid(copy_shader)


###############################################################################
# Everything after this point is designed to run on our rendering thread

func _setup_pipeline(shader_file: RDShaderFile) -> Dictionary:
	var shader_spirv: RDShaderSPIRV = shader_file.get_spirv()

	if shader_spirv.compile_error_compute != "":
		printerr(shader_spirv.compile_error_compute)
		return {}

	var _shader = rd.shader_create_from_spirv(shader_spirv)
	if !_shader.is_valid():
		printerr("Shader invalid compute pipeline %s " % shader_file.resource_name)
		return {}

	var _pipeline = rd.compute_pipeline_create(_shader)
	if !_pipeline.is_valid():
		printerr("Problem creating a compute pipeline  %s " % shader_file.resource_name)
		return {}
	return {
		"shader": _shader,
		"pipeline": _pipeline
	}


func _initialize_compute() -> bool:
	# Create our samplers
	var sampler_state : RDSamplerState = RDSamplerState.new()
	sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	nearest_sampler = rd.sampler_create(sampler_state)

	sampler_state = RDSamplerState.new()
	sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	linear_sampler = rd.sampler_create(sampler_state)

	# Create our shaders
	###### SETUP RECONSTRUCTION FILTER STEP
	var pipe_res = _setup_pipeline(load("res://addons/per_object_motion_blur/per_object_motion_blur.glsl"))
	if pipe_res.is_empty():
		return false
	shader = pipe_res.shader
	pipeline = pipe_res.pipeline
	
	####### SETUP COPY STEP DEPRECATED
	pipe_res = _setup_pipeline(load("res://addons/per_object_motion_blur/copy.glsl"))
	if pipe_res.is_empty():
		return false
	copy_shader = pipe_res.shader
	copy_pipeline = pipe_res.pipeline

	####### SETUP TILEMAX STEP
	pipe_res = _setup_pipeline(load("res://addons/per_object_motion_blur/tilemax.glsl"))
	if pipe_res.is_empty():
		return false
	tilemax_shader = pipe_res.shader
	tilemax_pipeline = pipe_res.pipeline
	
	
	pipe_res = _setup_pipeline(load("res://addons/per_object_motion_blur/neighbormax.glsl"))
	if pipe_res.is_empty():
		return false
	neighbormax_shader = pipe_res.shader
	neighbormax_pipeline = pipe_res.pipeline
	
	
	return true


func get_image_uniform(image : RID, binding : int = 0) -> RDUniform:
	var uniform : RDUniform = RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	uniform.binding = binding
	uniform.add_id(image)

	return uniform


func get_sampler_uniform(image : RID, binding : int = 0, linear : bool = true) -> RDUniform:
	var uniform : RDUniform = RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	uniform.binding = binding
	if linear:
		uniform.add_id(linear_sampler)
	else:
		uniform.add_id(nearest_sampler)
	uniform.add_id(image)

	return uniform


func _handle_textures_creation(render_scene_buffers: RenderSceneBuffersRD, texture_name: StringName, texture_size: Vector2i, format:  RenderingDevice.DataFormat):
	# If we have buffers for this viewport, check if they are the right size
	if render_scene_buffers.has_texture(context, texture_name):
		var tf : RDTextureFormat = render_scene_buffers.get_texture_format(context, texture_name)
		if tf.width != texture_size.x or tf.height != texture_size.y:
			# This will clear all textures for this viewport under this context
			render_scene_buffers.clear_context(context)
	else:
		var usage_bits : int = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
		render_scene_buffers.create_texture(context, texture_name, format, usage_bits, RenderingDevice.TEXTURE_SAMPLES_1, texture_size, 1, 1, true)


func _render_callback(p_effect_callback_type, p_render_data):
	if rd and p_effect_callback_type == CompositorEffect.EFFECT_CALLBACK_TYPE_POST_TRANSPARENT:
		var render_scene_buffers : RenderSceneBuffersRD = p_render_data.get_render_scene_buffers()
		if render_scene_buffers:
			# Get our render size, this is the 3D render resolution!
			var size = render_scene_buffers.get_internal_size()
			if size.x == 0 and size.y == 0:
				return
			var effect_size : Vector2 = size
			# Render our intermediate at half size

			# Radius `k` in px of dilatation filter, dictates the scale of intermiditate textures (w/k, h/k)
			var dilatate_radius_k: int = max(size.x, size.y) * blur_radius;
			
			_handle_textures_creation(render_scene_buffers, texture, effect_size, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT)
			_handle_textures_creation(render_scene_buffers, texture_tilemax, effect_size/dilatate_radius_k + Vector2.ONE, RenderingDevice.DATA_FORMAT_R16G16_SFLOAT)
			_handle_textures_creation(render_scene_buffers, texture_neighbormax, effect_size/dilatate_radius_k + Vector2.ONE, RenderingDevice.DATA_FORMAT_R16G16_SFLOAT)
			
			

			# We can use a compute shader here
			var x_groups = (effect_size.x - 1) / 8 + 1
			var y_groups = (effect_size.y - 1) / 8 + 1
			var z_groups = 1

			# Push constant
			var push_constant : PackedFloat32Array = PackedFloat32Array()
			push_constant.push_back(effect_size.x)
			push_constant.push_back(effect_size.y)
			push_constant.push_back(Engine.get_frames_per_second()) # current framerate
			push_constant.push_back(shutter_speed_hz)
			push_constant.push_back(dilatate_radius_k)
			push_constant.push_back(0)
			push_constant.push_back(0)
			push_constant.push_back(0)

			# Barrier Deprecated
			#rd.barrier(RenderingDevice.BARRIER_MASK_ALL_BARRIERS, RenderingDevice.BARRIER_MASK_COMPUTE)

			# Loop through views just in case we're doing stereo rendering. No extra cost if this is mono.
			var view_count = render_scene_buffers.get_view_count()
			for view in range(view_count):
				# Get the RID for our color image, we will be reading from and writing to it.
				var color_image = render_scene_buffers.get_color_layer(view)
				var velocity_image = render_scene_buffers.get_velocity_layer(view)
				var depth_image = render_scene_buffers.get_depth_layer(view)
				var texture_image = render_scene_buffers.get_texture_slice(context, texture, view, 0, 1, 1)
				
				var tilemax_image = render_scene_buffers.get_texture_slice(context, texture_tilemax, view, 0, 1, 1)
				var neighbormax_image = render_scene_buffers.get_texture_slice(context, texture_neighbormax, view, 0, 1, 1)
				
				##############################################################
				# Step 1 Create tile max texture

				# Create a uniform sets, this will be cached, the cache will be cleared if our viewports configuration is changed
				var uniform = get_sampler_uniform(velocity_image)
				var velocity_uniform_set = UniformSetCacheRD.get_cache(tilemax_shader, 0, [ uniform ])
				uniform = get_image_uniform(tilemax_image)
				var tilemax_uniform_set = UniformSetCacheRD.get_cache(tilemax_shader, 1, [ uniform ])
				# only FOR DEBUGGGUN!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
				uniform = get_image_uniform(neighbormax_image)
				var neighbormax_uniform_set = UniformSetCacheRD.get_cache(tilemax_shader, 2, [ uniform ])
				
				rd.draw_command_begin_label("Create tilemax buffer " + str(view), Color(1.0, 1.0, 1.0, 1.0))
				# Run our compute shader
				var compute_list := rd.compute_list_begin()
				rd.compute_list_bind_compute_pipeline(compute_list, tilemax_pipeline)
				rd.compute_list_bind_uniform_set(compute_list, velocity_uniform_set, 0)
				rd.compute_list_bind_uniform_set(compute_list, tilemax_uniform_set, 1)
				rd.compute_list_bind_uniform_set(compute_list, neighbormax_uniform_set, 2)
				rd.compute_list_set_push_constant(compute_list, push_constant.to_byte_array(), push_constant.size() * 4)
				# LATER REPLACE:
				rd.compute_list_dispatch(compute_list, (effect_size.x/dilatate_radius_k - 1) / 8 + 1, (effect_size.y/dilatate_radius_k - 1) / 8 + 1, 1)
				#rd.compute_list_dispatch(compute_list, x_groups, y_groups, z_groups)
				rd.compute_list_end()

				rd.draw_command_end_label()


				##############################################################
				# Step 2 Create tile max texture

				# Create a uniform sets, this will be cached, the cache will be cleared if our viewports configuration is changed
				uniform = get_image_uniform(tilemax_image)
				tilemax_uniform_set = UniformSetCacheRD.get_cache(neighbormax_shader, 1, [ uniform ])
				uniform = get_image_uniform(neighbormax_image)
				neighbormax_uniform_set = UniformSetCacheRD.get_cache(neighbormax_shader, 2, [ uniform ])
				
				rd.draw_command_begin_label("Create neighbormax buffer " + str(view), Color(1.0, 1.0, 1.0, 1.0))
				# Run our compute shader
				compute_list = rd.compute_list_begin()
				rd.compute_list_bind_compute_pipeline(compute_list, neighbormax_pipeline)
				rd.compute_list_bind_uniform_set(compute_list, tilemax_uniform_set, 1)
				rd.compute_list_bind_uniform_set(compute_list, neighbormax_uniform_set, 2)
				rd.compute_list_set_push_constant(compute_list, push_constant.to_byte_array(), push_constant.size() * 4)
				# LATER REPLACE:
				rd.compute_list_dispatch(compute_list, (effect_size.x/dilatate_radius_k - 1) / 8 + 1, (effect_size.y/dilatate_radius_k - 1) / 8 + 1, 1)
				#rd.compute_list_dispatch(compute_list, x_groups, y_groups, z_groups)
				rd.compute_list_end()

				rd.draw_command_end_label()
				
				# Step 3: Copy Color layer to texture

				# Create a uniform sets, this will be cached, the cache will be cleared if our viewports configuration is changed
				uniform = get_image_uniform(color_image)
				var color_uniform_set = UniformSetCacheRD.get_cache(copy_shader, 0, [ uniform ])
				uniform = get_image_uniform(texture_image)
				var texture_uniform_set = UniformSetCacheRD.get_cache(copy_shader, 1, [ uniform ])

				rd.draw_command_begin_label("Copy color texture " + str(view), Color(1.0, 1.0, 1.0, 1.0))
				# Run our compute shader
				compute_list = rd.compute_list_begin()
				rd.compute_list_bind_compute_pipeline(compute_list, copy_pipeline)
				rd.compute_list_bind_uniform_set(compute_list, color_uniform_set, 0)
				rd.compute_list_bind_uniform_set(compute_list, texture_uniform_set, 1)
				rd.compute_list_set_push_constant(compute_list, push_constant.to_byte_array(), push_constant.size() * 4)
				rd.compute_list_dispatch(compute_list, x_groups, y_groups, z_groups)
				rd.compute_list_end()

				rd.draw_command_end_label()

				##############################################################
				# Step 4: Do a per object motion blur

				# Create a uniform sets, this will be cached, the cache will be cleared if our viewports configuration is changed
				uniform = get_image_uniform(color_image)
				color_uniform_set = UniformSetCacheRD.get_cache(shader, 0, [ uniform ])

				uniform = get_image_uniform(texture_image)
				texture_uniform_set = UniformSetCacheRD.get_cache(shader, 1, [ uniform ])

				uniform = get_sampler_uniform(velocity_image)
				velocity_uniform_set = UniformSetCacheRD.get_cache(shader, 2, [ uniform ])

				uniform = get_sampler_uniform(depth_image)
				var depth_uniform_set = UniformSetCacheRD.get_cache(shader, 3, [ uniform ])

				uniform = get_image_uniform(neighbormax_image)
				neighbormax_uniform_set = UniformSetCacheRD.get_cache(shader, 4, [ uniform ])



				rd.draw_command_begin_label("Per Object Motion Blur " + str(view), Color(1.0, 1.0, 1.0, 1.0))
				# Run our compute shader
				compute_list = rd.compute_list_begin()
				rd.compute_list_bind_compute_pipeline(compute_list, pipeline)
				rd.compute_list_bind_uniform_set(compute_list, color_uniform_set, 0)
				rd.compute_list_bind_uniform_set(compute_list, texture_uniform_set, 1)
				rd.compute_list_bind_uniform_set(compute_list, velocity_uniform_set, 2)
				rd.compute_list_bind_uniform_set(compute_list, depth_uniform_set, 3)
				rd.compute_list_bind_uniform_set(compute_list, neighbormax_uniform_set, 4)
				rd.compute_list_set_push_constant(compute_list, push_constant.to_byte_array(), push_constant.size() * 4)
				rd.compute_list_dispatch(compute_list, x_groups, y_groups, z_groups)
				rd.compute_list_end()

				rd.draw_command_end_label()
