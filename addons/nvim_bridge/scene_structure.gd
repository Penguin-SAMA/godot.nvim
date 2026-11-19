@tool
extends RefCounted


static func _error(message: String) -> Dictionary:
	return {"error": message + " Use the Godot editor for this edit."}


static func _resolve(root: Node, path: Variant) -> Node:
	if not path is String or path.is_empty():
		return null
	var parsed := NodePath(path)
	if parsed.is_absolute() or parsed.get_subname_count() != 0 or ".." in path.split("/"):
		return null
	return root.get_node_or_null(parsed)


static func _local_error(root: Node, node: Node) -> String:
	while node != root:
		if not node.scene_file_path.is_empty():
			return "Cannot edit across a scene instance boundary."
		if node.owner != root:
			return "Cannot edit across a scene ownership boundary."
		node = node.get_parent()
	return ""


static func _branch(node: Node, result: Array[Node], include_internal := false) -> void:
	result.append(node)
	for child in node.get_children(include_internal):
		_branch(child, result, include_internal)


static func _touches(edited: Node, other: Node) -> bool:
	return other == edited or edited.is_ancestor_of(other)


static func _path_target(source: Node, path: NodePath) -> Node:
	# A property-only path identifies the source itself.
	return source.get_node_or_null(NodePath(path.get_concatenated_names())) if path.get_name_count() else source


static func _unsafe_path(edited: Node, source: Node, path: NodePath) -> bool:
	if path.is_empty():
		return false
	if path.is_absolute() or _touches(edited, source):
		return true
	# Resolve each cumulative prefix with Godot's resolver: '..' and '%Name'
	# can leave the edited branch even when the endpoint is unaffected.
	var prefix := ""
	for index in path.get_name_count():
		if index > 0:
			prefix += "/"
		prefix += String(path.get_name(index))
		var step := source.get_node_or_null(NodePath(prefix))
		if step == null or _touches(edited, step):
			return true
	return false


static func _unsafe_value(edited: Node, source: Node, value: Variant, seen: Array, unknown_context := false) -> bool:
	if value is NodePath:
		return not value.is_empty() if unknown_context else _unsafe_path(edited, source, value)
	if value is Node:
		return unknown_context or _touches(edited, source) or _touches(edited, value)
	if not (value is Array or value is Dictionary or value is Resource):
		return false
	# PackedScenes are independent hierarchies; Script contents are not scanned.
	if value is Script or value is PackedScene:
		return false
	for entry in seen:
		if entry[0] == unknown_context and is_same(entry[1], value):
			return false
	seen.append([unknown_context, value])
	if value is Array or value is Dictionary:
		for item in value:
			if _unsafe_value(edited, source, item, seen, unknown_context):
				return true
			if value is Dictionary and _unsafe_value(edited, source, value[item], seen, unknown_context):
				return true
		return false
	if value is Animation:
		# Track paths have a mixer-relative base. Key data does not: a key can
		# assign a path or pass it to arbitrary code on a different node.
		for track in value.get_track_count():
			for key in value.track_get_key_count(track):
				if _unsafe_value(edited, source, value.track_get_key_value(track, key), seen, true):
					return true
		return false
	return _unsafe_properties(edited, source, value, seen, unknown_context)


static func _unsafe_properties(edited: Node, source: Node, object: Object, seen: Array, unknown_context := false) -> bool:
	for property in object.get_property_list():
		if property.usage & PROPERTY_USAGE_STORAGE:
			if _unsafe_value(edited, source, object.get(property.name), seen, unknown_context):
				return true
	return false


static func _unsafe_animation(edited: Node, mixer: AnimationMixer) -> bool:
	var base := _path_target(mixer, mixer.root_node)
	for animation_name in mixer.get_animation_list():
		var animation := mixer.get_animation(animation_name)
		for index in animation.get_track_count():
			if base == null or _unsafe_path(edited, mixer, mixer.root_node) or _unsafe_path(edited, base, animation.track_get_path(index)):
				return true
	return false


static func _reference_error(root: Node, edited: Node) -> String:
	var nodes: Array[Node] = []
	_branch(root, nodes)
	for source in nodes:
		if _unsafe_properties(edited, source, source, []):
			return "Unsafe serialized reference on %s." % root.get_path_to(source)
		for signal_info in source.get_signal_list():
			for connection in source.get_signal_connection_list(signal_info.name):
				if not connection.flags & Object.CONNECT_PERSIST:
					continue
				var callback: Callable = connection.callable
				var target := callback.get_object() as Node
				if target == null or _touches(edited, source) or _touches(edited, target) or _unsafe_value(edited, source, callback.get_bound_arguments(), []):
					return "Unsafe persistent signal reference on %s." % root.get_path_to(source)
		if source is AnimationMixer and _unsafe_animation(edited, source):
			return "Unsafe animation track reference on %s." % root.get_path_to(source)
	return ""


static func prepare(root: Node, method: String, p: Dictionary) -> Dictionary:
	var node := _resolve(root, p.get("node"))
	if node == null:
		return _error("Node no longer exists or its path is invalid.")
	if node == root:
		return _error("Cannot edit the scene root.")
	var packed := ResourceLoader.load(root.scene_file_path, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	if packed == null or packed.get_state().get_node_count() == 0:
		return _error("Cannot verify the saved scene structure.")
	if packed.get_state().get_node_instance(0) != null:
		return _error("Cannot edit an inherited scene.")
	var old_parent := node.get_parent()
	var parent := old_parent
	var label := String(node.name)
	match method:
		"rename_node":
			if not p.get("name") is String:
				return _error("Invalid node name.")
			label = p.name
			if label.strip_edges().is_empty() or label != label.validate_node_name() or label in [".", ".."]:
				return _error("Invalid node name.")
			if node.unique_name_in_owner and node.owner != null:
				var claimed := node.owner.get_node_or_null(NodePath("%" + label))
				if claimed != null and claimed != node and claimed.owner == node.owner:
					return _error("Another node already has that unique name in the scene.")
		"reparent_node":
			parent = _resolve(root, p.get("parent"))
			if parent == null:
				return _error("Destination parent no longer exists or its path is invalid.")
			if _touches(node, parent):
				return _error("Cannot reparent: the move would create a cycle.")
			if parent == old_parent:
				return _error("Destination is already the current parent.")
		"delete_node":
			pass
		_:
			return _error("Unknown structural operation.")
	if method != "delete_node":
		for sibling in parent.get_children(true):
			if sibling != node and sibling.name == label:
				return _error("A sibling already has that name.")
	var branch: Array[Node] = []
	_branch(node, branch, true)
	var owners := {}
	for member in branch:
		var why := _local_error(root, member)
		if why != "":
			return _error(why)
		owners[member] = member.owner
	var why := _local_error(root, parent)
	if why == "":
		why = _reference_error(root, node)
	if why != "":
		return _error(why)
	var local_transform: Variant = node.transform if node is Node2D or node is Node3D else null
	return {"node": node, "name": label, "parent": parent, "old_parent": old_parent,
		"index": node.get_index(), "owners": owners, "transform": local_transform}
