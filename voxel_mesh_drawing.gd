extends Node3D

@onready var export_as_gltf = %"export as gltf"
@onready var new_mesh = %"new mesh"
@onready var clear_meshes = %"clear meshes"
@onready var meshparent = $meshparent
@onready var density_range = %density_range
@onready var sub_viewport_container = $"../.."


## distance in meters (godot units) between each voxel point
@export var density : float = 0.1
## material used on the linemesh
@export var mat : StandardMaterial3D

var points : Dictionary
var new_entries :Array[Dictionary] 

var events : Array[Dictionary] = []
var mesh_semaphore := Semaphore.new()
var dictionary_semaphore := Semaphore.new()
var dictionary_mutex := Mutex.new()
var mesh_thread := Thread.new()
var dictionary_thread := Thread.new()

var mesh : MeshInstance3D
var armesh : ArrayMesh

var strokes :Array[MeshInstance3D] = []

var undo_pressed := false

func _ready():
	density = density_range.value
	sub_viewport_container.focus_entered.connect(func():
		sub_viewport_container.release_focus()
		)
	sub_viewport_container.gui_input.connect(func(event:InputEvent):
		if event is InputEventMouseButton:
			sub_viewport_container.grab_focus()
			sub_viewport_container.release_focus()
		)
	density_range.value_changed.connect(func(val:float):
		density = val
		)
	clear_meshes.pressed.connect(func():
		for child in meshparent.get_children():
			await get_tree().process_frame
			child.queue_free()
		new_stroke()
		)
	new_mesh.pressed.connect(func():
		new_stroke()
		)
	export_as_gltf.pressed.connect(func():
		var state := GLTFState.new()
		var doc := GLTFDocument.new()
		doc.append_from_scene(meshparent,state)
		if OS.get_name() == "Web":
			var gltfbuffer := doc.generate_buffer(state)
			JavaScriptBridge.download_buffer(gltfbuffer,"voxel_drawing.glb")
		else:
			var downpath :String=OS.get_system_dir(OS.SYSTEM_DIR_DOWNLOADS)
			downpath += "/"
			doc.write_to_filesystem(state,downpath+"voxel_drawing.gltf")
		
		)
	
	mesh_thread.start(_update_mesh_thread)
	dictionary_thread.start(_update_dictionary_thread)

func new_stroke():
	mesh = MeshInstance3D.new()
	armesh = ArrayMesh.new()
	mesh.mesh = armesh
	mesh.material_override = mat
	points.clear()
	strokes.append(mesh)
	meshparent.add_child(mesh)

func _input(event):
	if event is InputEventKey:
		if event.ctrl_pressed and event.physical_keycode == KEY_Z and !strokes.is_empty():
			if event.pressed:
				if !undo_pressed:
					undo_pressed = true
					strokes.pop_back().queue_free()
			else:
				undo_pressed = false

func set_true_nearest(global_point:Vector3):
	var local_point :Vector3 = (to_local(global_point)*(1.0/density))
	points[ round(local_point) ] = true
	#_update_mesh()
	mesh_semaphore.post()

func set_false_nearest(global_point:Vector3):
	var local_point :Vector3 = (to_local(global_point)*(1.0/density))
	dictionary_mutex.lock()
	if points.has(round(local_point)):
		points.erase(round(local_point))
	dictionary_mutex.unlock()
	#_update_mesh()
	mesh_semaphore.post()

func set_true_cube(global_point:Vector3, size:float):
	var local_point :Vector3 = (to_local(global_point)*(1.0/density))
	var radius_int := int( (size/2)*(1/density) )
	for x in radius_int*2:
		for y in radius_int*2:
			for z in radius_int*2:
				var offset := Vector3(x-radius_int,y-radius_int,z-radius_int)
				points[ round(local_point+offset) ] = true
	#points[ round(local_point) ] = true
	#_update_mesh()
	dictionary_semaphore.post()

func set_true_sphere(global_point:Vector3,size:float):
	var local_point :Vector3 = (to_local(global_point)*(1.0/density))
	events.append({"action":"_set_true_sphere", "local_point":local_point,"size":size})
	dictionary_semaphore.post()

func _set_true_sphere(local_point:Vector3, size:float):
	#var local_point :Vector3 = (to_local(global_point)*(1.0/density))
	var dict:Dictionary
	var radius_int := int( ((size/2.0)/density) )
	for x in radius_int*2:
		for y in radius_int*2:
			for z in radius_int*2:
				var offset := Vector3(x-radius_int,y-radius_int,z-radius_int)
				#if local_point.distance_to(offset+local_point) <= (size/2.0)/density and local_point.distance_to(offset+local_point) > ((size/2.0)/density)*.9:
				if local_point.distance_to(offset+local_point) <= (size/2.0)/density:
					dict[ round(local_point+offset) ] = true
	dictionary_mutex.lock()
	points.merge(dict,true)
	dictionary_mutex.unlock()
	#points[ round(local_point) ] = true
	#_update_mesh()
	#dictionary_semaphore.post()

func set_false_sphere(global_point:Vector3,size:float):
	var local_point :Vector3 = (to_local(global_point)*(1.0/density))
	events.append({"action":"_set_false_sphere", "local_point":local_point,"size":size})
	dictionary_semaphore.post()

func _set_false_sphere(local_point:Vector3, size:float):
	var dict:Dictionary
	#var local_point :Vector3 = (to_local(global_point)*(1.0/density))
	var radius_int := int( (size/2.0)*(1.0/density) )
	for x in radius_int*2:
		for y in radius_int*2:
			for z in radius_int*2:
				var offset := Vector3(x-radius_int,y-radius_int,z-radius_int)
				if local_point.distance_to(offset+local_point) <= (size/2.0)/density:
					dictionary_mutex.lock()
					points.erase(round(local_point+offset))
					dictionary_mutex.unlock()
	
	#points[ round(local_point) ] = true
	#_update_mesh()
	#dictionary_semaphore.post()

func _update_mesh_thread():
	while true:
		mesh_semaphore.wait()
		_update_mesh()

func _update_mesh():
	var vertices = PackedVector3Array()
	dictionary_mutex.lock()
	var keys := points.duplicate(true)
	dictionary_mutex.unlock()
	for i in keys:
		#we're gonna start with cubes
		if !keys.has(i+Vector3(0,0,-1)):
			_add_back_quad(vertices,i)
		if !keys.has(i+Vector3(0,-1,0)):
			_add_bottom_quad(vertices,i)
		if !keys.has(i+Vector3(0,1,0)):
			_add_top_quad(vertices,i)
		if !keys.has(i+Vector3(0,0,1)):
			_add_front_quad(vertices,i)
		if !keys.has(i+Vector3(-1,0,0)):
			_add_left_quad(vertices,i)
		if !keys.has(i+Vector3(1,0,0)):
			_add_right_quad(vertices,i)
	
	var arrays = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices

	# Create the Mesh.
	armesh.clear_surfaces()
	armesh.call_deferred("add_surface_from_arrays",Mesh.PRIMITIVE_TRIANGLES, arrays,[],{},536870912)
	#armesh.call_deferred("add_surface_from_arrays",Mesh.PRIMITIVE_TRIANGLES, arrays)

func _update_dictionary_thread():
	while true:
		dictionary_semaphore.wait()
		var event :Dictionary= events.pop_front()
		match event.action:
			"_set_true_sphere":
				_set_true_sphere(event.local_point,event.size)
			"_set_false_sphere":
				_set_false_sphere(event.local_point,event.size)
		mesh_semaphore.post()

func _add_cube_to_array(array:PackedVector3Array, pos:Vector3):
	#these need to be tris, so here we go
	# for reference i am thinking of front as z+, right as x+, and up as y+
	var offset := Vector3()
	var ofs := density/2.0
	_add_back_quad(array,pos)
	_add_bottom_quad(array,pos)
	_add_front_quad(array,pos)
	_add_left_quad(array,pos)
	_add_right_quad(array,pos)

func _add_left_quad(array:PackedVector3Array, pos:Vector3):
	var offset := Vector3()
	var ofs := density/2.0
	# bottom left tri
	offset = Vector3(-ofs,ofs,ofs)
	array.append((pos*density)+offset)
	offset = Vector3(-ofs,-ofs,ofs)
	array.append((pos*density)+offset)
	offset = Vector3(-ofs,-ofs,-ofs)
	array.append((pos*density)+offset)
	# top left tri
	offset = Vector3(-ofs,-ofs,-ofs)
	array.append((pos*density)+offset)
	offset = Vector3(-ofs,ofs,-ofs)
	array.append((pos*density)+offset)
	offset = Vector3(-ofs,ofs,ofs)
	array.append((pos*density)+offset)

func _add_right_quad(array:PackedVector3Array, pos:Vector3):
	var offset := Vector3()
	var ofs := density/2.0
	# bottom right tri
	offset = Vector3(ofs,-ofs,-ofs)
	array.append((pos*density)+offset)
	offset = Vector3(ofs,-ofs,ofs)
	array.append((pos*density)+offset)
	offset = Vector3(ofs,ofs,ofs)
	array.append((pos*density)+offset)
	# top right tri
	offset = Vector3(ofs,ofs,ofs)
	array.append((pos*density)+offset)
	offset = Vector3(ofs,ofs,-ofs)
	array.append((pos*density)+offset)
	offset = Vector3(ofs,-ofs,-ofs)
	array.append((pos*density)+offset)

func _add_back_quad(array:PackedVector3Array, pos:Vector3):
	var offset := Vector3()
	var ofs := density/2.0
	# bottom back tri
	offset = Vector3(ofs,-ofs,-ofs)
	array.append((pos*density)+offset)
	offset = Vector3(ofs,ofs,-ofs)
	array.append((pos*density)+offset)
	offset = Vector3(-ofs,-ofs,-ofs)
	array.append((pos*density)+offset)
	# top back tri
	offset = Vector3(-ofs,-ofs,-ofs)
	array.append((pos*density)+offset)
	offset = Vector3(ofs,ofs,-ofs)
	array.append((pos*density)+offset)
	offset = Vector3(-ofs,ofs,-ofs)
	array.append((pos*density)+offset)

func _add_front_quad(array:PackedVector3Array, pos:Vector3):
	var offset := Vector3()
	var ofs := density/2.0
	# bottom front tri
	offset = Vector3(-ofs,-ofs,ofs)
	array.append((pos*density)+offset)
	offset = Vector3(ofs,ofs,ofs)
	array.append((pos*density)+offset)
	offset = Vector3(ofs,-ofs,ofs)
	array.append((pos*density)+offset)
	# top front tri
	offset = Vector3(-ofs,ofs,ofs)
	array.append((pos*density)+offset)
	offset = Vector3(ofs,ofs,ofs)
	array.append((pos*density)+offset)
	offset = Vector3(-ofs,-ofs,ofs)
	array.append((pos*density)+offset)

func _add_top_quad(array:PackedVector3Array, pos:Vector3):
	var offset := Vector3()
	var ofs := density/2.0
	# top back tri
	offset = Vector3(-ofs,ofs,-ofs)
	array.append((pos*density)+offset)
	offset = Vector3(ofs,ofs,ofs)
	array.append((pos*density)+offset)
	offset = Vector3(-ofs,ofs,ofs)
	array.append((pos*density)+offset)
	# top front tri
	offset = Vector3(-ofs,ofs,-ofs)
	array.append((pos*density)+offset)
	offset = Vector3(ofs,ofs,-ofs)
	array.append((pos*density)+offset)
	offset = Vector3(ofs,ofs,ofs)
	array.append((pos*density)+offset)

func _add_bottom_quad(array:PackedVector3Array, pos:Vector3):
	var offset := Vector3()
	var ofs := density/2.0
	# bottom back tri
	offset = Vector3(-ofs,-ofs,ofs)
	array.append((pos*density)+offset)
	offset = Vector3(ofs,-ofs,ofs)
	array.append((pos*density)+offset)
	offset = Vector3(-ofs,-ofs,-ofs)
	array.append((pos*density)+offset)
	# bottom front tri
	offset = Vector3(ofs,-ofs,ofs)
	array.append((pos*density)+offset)
	offset = Vector3(ofs,-ofs,-ofs)
	array.append((pos*density)+offset)
	offset = Vector3(-ofs,-ofs,-ofs)
	array.append((pos*density)+offset)
