@tool
extends RefCounted

var plugin: EditorPlugin
var disk_versions := {}
var known_actions := {}
var editing_history := false
var history_events := 0


func _init(editor_plugin: EditorPlugin) -> void:
	plugin = editor_plugin
	if DisplayServer.get_name() == "headless":
		return
	# A tab that predates the add-on may already be stale. A tab switch is
	# not a reload, so never seed its baseline from an arbitrary disk read.
	for root in EditorInterface.get_open_scene_roots():
		if root and root.scene_file_path != "":
			_remember(root, "")
	plugin.scene_changed.connect(_scene_changed)
	plugin.scene_saved.connect(_scene_saved)
	plugin.scene_closed.connect(func(path: String): disk_versions.erase(path))
	var manager := plugin.get_undo_redo()
	manager.history_changed.connect(_history_changed)
	manager.version_changed.connect(_history_changed)


func _history_changed() -> void:
	# These notifications include commits, clears, undo and redo. An edit made
	# elsewhere makes the relative order of scene and global actions unknown.
	history_events += 1
	if not editing_history:
		known_actions.clear()


func _action_key(root: Node, history: UndoRedo) -> String:
	return "%s:%s:%s" % [root.get_instance_id(), history.get_version(), history.get_current_action_name()]


func _commit(root: Node, execute := true) -> void:
	var manager := plugin.get_undo_redo()
	var previous := history_events
	editing_history = true
	manager.commit_action(execute)
	editing_history = false
	if history_events != previous + 1:
		known_actions.clear()
		return
	var history := manager.get_history_undo_redo(manager.get_object_history_id(root))
	known_actions[_action_key(root, history)] = true


func _digest(path: String) -> String:
	return FileAccess.get_sha256(path) if FileAccess.file_exists(path) else ""


func _remember(root: Node, digest: String) -> void:
	disk_versions[root.scene_file_path] = {"id": root.get_instance_id(), "digest": digest}


func _scene_changed(root: Node) -> void:
	if root == null or root.scene_file_path == "":
		return
	var version: Dictionary = disk_versions.get(root.scene_file_path, {})
	if version.get("id", 0) != root.get_instance_id():
		_remember(root, _digest(root.scene_file_path))


func _scene_saved(path: String) -> void:
	for root in EditorInterface.get_open_scene_roots():
		if root and root.scene_file_path == path:
			_remember(root, _digest(path))
			break


func _disk_conflict(root: Node) -> String:
	var path := root.scene_file_path
	var version: Dictionary = disk_versions.get(path, {})
	if version.get("id", 0) != root.get_instance_id() or version.get("digest", "") == "":
		return "Reload the scene in Godot before editing it from Neovim: " + path
	if version.digest != _digest(path):
		return "Scene changed on disk. Resolve the change or reload the scene in Godot: " + path
	return ""


static func valid_resource(path: String) -> bool:
	if not path.begins_with("res://") or path.length() <= 6 or path.contains("\\"):
		return false
	for part in path.substr(6).split("/"):
		if part in ["", ".", "..", ".godot"] or part.contains(":"):
			return false
	return true


func _scene(path: String) -> Node:
	var root := EditorInterface.get_edited_scene_root()
	if path == "":
		if root != null and root.scene_file_path != "":
			return root
		path = ProjectSettings.get_setting("application/run/main_scene", "")
	if path.begins_with("uid://"):
		var uid := ResourceUID.text_to_id(path)
		path = ResourceUID.get_id_path(uid) if ResourceUID.has_id(uid) else ""
	if not valid_resource(path) or path.get_extension() not in ["tscn", "scn"] or not FileAccess.file_exists(path):
		return null
	if root != null and root.scene_file_path == path:
		return root
	var already_open := path in EditorInterface.get_open_scenes()
	var disk_before_open := "" if already_open else _digest(path)
	EditorInterface.open_scene_from_path(path)
	for frame in 60:
		await plugin.get_tree().process_frame
		root = EditorInterface.get_edited_scene_root()
		if root != null and root.scene_file_path == path:
			if not already_open:
				_remember(root, disk_before_open)
			return root
	return null


func _node(root: Node, path: String) -> Node:
	if path == ".":
		return root
	if path == "" or path.begins_with("/") or path.contains(":") or ".." in path.split("/"):
		return null
	var node := root.get_node_or_null(NodePath(path))
	if node != null and node.owner == root:
		return node
	return null


func _info(node: Node, root: Node) -> Dictionary:
	var script: Script = node.get_script()
	var type := node.get_class()
	if script != null and script.get_global_name() != &"":
		type = script.get_global_name()
	var info := {"name": String(node.name), "variable": String(node.name).to_snake_case(),
		"path": String(root.get_path_to(node)), "type": type, "unique": node.unique_name_in_owner,
		"script": script.resource_path if script else "", "children": []}
	for child in node.get_children():
		if child.owner == root:
			info.children.append(_info(child, root))
	return info


func _save(result: Dictionary) -> Dictionary:
	var root := EditorInterface.get_edited_scene_root()
	var conflict := _disk_conflict(root)
	if conflict != "":
		return {"error": "Godot changed the open scene but did not save it. " + conflict}
	var err := EditorInterface.save_scene()
	if err != OK:
		return {"error": "Scene changed in Godot, but saving failed: " + error_string(err)}
	_remember(root, _digest(root.scene_file_path))
	return result


func _creatable(type: String) -> bool:
	return ClassDB.class_exists(type) and ClassDB.is_parent_class(type, "Node") and ClassDB.can_instantiate(type) and ClassDB.class_get_api_type(type) == ClassDB.API_CORE


func _types() -> Array:
	var result := ["Node"]
	for type in ClassDB.get_inheriters_from_class("Node"):
		if _creatable(type):
			result.append(String(type))
	for entry in ProjectSettings.get_global_class_list():
		var script: Script = load(entry.path)
		if script and ClassDB.is_parent_class(script.get_instance_base_type(), "Node") and not script.is_abstract():
			result.append(String(entry["class"]))
	result.sort()
	return result


func _add(root: Node, p: Dictionary) -> Dictionary:
	var parent := _node(root, str(p.get("parent", ".")))
	var type := str(p.get("type", ""))
	var label := str(p.get("name", type))
	if parent == null or label == "" or label != label.validate_node_name():
		return {"error": "Invalid parent or node name: " + label}
	var node: Node
	if _creatable(type):
		node = ClassDB.instantiate(type)
	else:
		for entry in ProjectSettings.get_global_class_list():
			if entry["class"] == type:
				var script: Script = load(entry.path)
				if script and _creatable(script.get_instance_base_type()) and not script.is_abstract():
					node = ClassDB.instantiate(script.get_instance_base_type())
					node.set_script(script)
				break
	if node == null:
		return {"error": "Unknown or abstract node type: " + type}
	node.name = label
	var undo := plugin.get_undo_redo()
	undo.create_action("Add " + label, UndoRedo.MERGE_DISABLE, root)
	undo.add_do_method(parent, "add_child", node, true)
	undo.add_do_method(node, "set_owner", root)
	undo.add_do_reference(node)
	undo.add_undo_method(parent, "remove_child", node)
	_commit(root)
	return _save({"path": String(root.get_path_to(node))})


func _attach(root: Node, p: Dictionary) -> Dictionary:
	var node := _node(root, str(p.get("node", "")))
	var path := str(p.get("script_path", ""))
	if node == null or not valid_resource(path) or path.get_extension() != "gd":
		return {"error": "Choose a project .gd file and a scene node"}
	var current: Script = node.get_script()
	if current != null:
		if current.resource_path == path:
			return {"script": path}
		return {"error": "A script is already attached to this node: " + current.resource_path}
	if path in p.get("modified", []):
		return {"error": "Save the modified Neovim buffer first: " + path}
	if not FileAccess.file_exists(path):
		var template := GDScript.new()
		template.source_code = "extends %s\n" % node.get_class()
		if template.reload() != OK or ResourceSaver.save(template, path) != OK:
			return {"error": "Unable to create " + path + ". Choose an existing directory."}
		EditorInterface.get_resource_filesystem().update_file(path)
	# The generated template can still be pathless after saving. Attach the
	# external resource so PackedScene keeps a link to the editable .gd file.
	var script := load(path) as GDScript
	if not script or script.resource_path != path or script.is_abstract() or not node.is_class(script.get_instance_base_type()):
		return {"error": "Script cannot be attached to this node: " + path}
	var undo := plugin.get_undo_redo()
	undo.create_action("Attach " + path.get_file(), UndoRedo.MERGE_DISABLE, root)
	undo.add_do_method(node, "set_script", script)
	undo.add_undo_method(node, "set_script", null)
	_commit(root)
	return _save({"script": path})


func _signals(node: Node) -> Array:
	var result := []
	for item in node.get_signal_list():
		var args := []
		for arg in item.args:
			args.append(String(arg.name))
		result.append({"name": String(item.name), "args": args})
	return result


func _script_has(script: Script, method: String) -> bool:
	while script:
		for entry in script.get_script_method_list():
			if entry.name == method:
				return true
		script = script.get_base_script()
	return false


func _source_matches(script: GDScript, expected: String) -> bool:
	if FileAccess.get_file_as_string(script.resource_path).replace("\r\n", "\n") != expected:
		return false
	if script.resource_path in EditorInterface.get_script_editor().get_unsaved_files():
		return false
	return script.source_code.replace("\r\n", "\n") == expected


# Bind the stub and connection to one scene history action. Undo/redo must
# never replace script edits made after the original action.
func _replace_source(script: GDScript, expected: String, replacement: String) -> bool:
	if not _source_matches(script, expected):
		push_warning("Neovim bridge kept later edits to " + script.resource_path)
		return false
	script.source_code = replacement
	if script.reload(true) != OK or ResourceSaver.save(script) != OK:
		script.source_code = expected
		script.reload(true)
		return false
	var editor := EditorInterface.get_script_editor()
	if script in editor.get_open_scripts():
		editor.reload_open_files()
	return true


func _connect(root: Node, p: Dictionary) -> Dictionary:
	var src := _node(root, str(p.get("source", "")))
	var dst := _node(root, str(p.get("target", "")))
	var sig := str(p.get("signal", ""))
	var method := str(p.get("method", ""))
	if src == null or dst == null or not src.has_signal(sig) or not method.is_valid_ascii_identifier():
		return {"error": "Invalid signal, callback name, source, or target"}
	var script := dst.get_script() as GDScript
	if script == null or not valid_resource(script.resource_path):
		return {"error": "Attach an external GDScript to the destination first"}
	var callback := Callable(dst, method)
	if src.is_connected(sig, callback):
		return {"error": "Signal already connected to " + method}
	var original := script.source_code.replace("\r\n", "\n")
	var updated := original
	if not _script_has(script, method) and not ClassDB.class_has_method(dst.get_class(), method):
		if script.resource_path in p.get("modified", []) or not _source_matches(script, original):
			return {"error": "Save and synchronize the modified script first: " + script.resource_path}
		var args := PackedStringArray()
		for entry in _signals(src):
			if entry.name == sig:
				for i in entry.args.size():
					var arg := str(entry.args[i])
					args.append("_" + (arg if arg.is_valid_ascii_identifier() else "arg%d" % i))
		updated = original + "\n\nfunc %s(%s) -> void:\n\tpass\n" % [method, ", ".join(args)]
		if not _replace_source(script, original, updated):
			return {"error": "Could not create callback in " + script.resource_path}
	var err := src.connect(sig, callback, CONNECT_PERSIST)
	if err != OK:
		if updated != original:
			_replace_source(script, updated, original)
		return {"error": "Could not connect signal: " + error_string(err)}
	var undo := plugin.get_undo_redo()
	var label := "Connect %s to %s" % [sig, method]
	if updated != original:
		label += " in " + script.resource_path
	undo.create_action(label, UndoRedo.MERGE_DISABLE, root)
	if updated != original:
		undo.add_do_method(self, "_replace_source", script, original, updated)
	undo.add_do_method(src, "connect", sig, callback, CONNECT_PERSIST)
	undo.add_undo_method(src, "disconnect", sig, callback)
	if updated != original:
		undo.add_undo_method(self, "_replace_source", script, updated, original)
	_commit(root, false)
	return _save({"script": script.resource_path, "method": method, "generated": updated != original})


func _undo(root: Node, modified: Array) -> Dictionary:
	var manager := plugin.get_undo_redo()
	var history := manager.get_history_undo_redo(manager.get_object_history_id(root))
	if not history or not history.has_undo():
		return {"error": "No scene action to undo"}
	for path in modified:
		if history.get_current_action_name().ends_with(" in " + str(path)):
			return {"error": "Save the modified Neovim buffer first: " + str(path)}
	# Godot exposes the underlying UndoRedo for inspection, but invoking its
	# undo() bypasses EditorUndoRedoManager's history and saved-version stacks.
	var key := _action_key(root, history)
	if not known_actions.has(key):
		for id in [EditorUndoRedoManager.GLOBAL_HISTORY, EditorUndoRedoManager.REMOTE_HISTORY]:
			var other := manager.get_history_undo_redo(id)
			if other and other.has_undo():
				return {"error": "Undo order is ambiguous. Select Scene only in Godot's History dock."}
	var settings := EditorInterface.get_editor_settings()
	var undo_shortcut := settings.get_shortcut("ui_undo")
	var reload_shortcut := settings.get_shortcut("editor/reload_saved_scene")
	if undo_shortcut and reload_shortcut:
		for menu: PopupMenu in EditorInterface.get_base_control().find_children("*", "PopupMenu", true, false):
			var undo_index := -1
			var is_scene_menu := false
			for i in menu.item_count:
				var shortcut := menu.get_item_shortcut(i)
				if shortcut == undo_shortcut:
					undo_index = i
				if shortcut == reload_shortcut:
					is_scene_menu = true
			if is_scene_menu and undo_index >= 0 and not menu.is_item_disabled(undo_index):
				var previous := history.get_version()
				var previous_events := history_events
				editing_history = true
				menu.id_pressed.emit(menu.get_item_id(undo_index))
				editing_history = false
				if history_events != previous_events + 1:
					known_actions.clear()
				if history.get_version() < previous:
					known_actions.erase(key)
					return _save({"undone": true})
				break
	return {"error": "Godot could not undo the last scene action. Use the History dock."}


func dispatch(method: String, p: Dictionary) -> Variant:
	if method == "creatable_types":
		return _types()
	if method not in ["scene_tree", "add_node", "attach_script", "signals", "connect_signal", "undo"]:
		return {"error": "Unknown bridge method: " + method}
	var root := await _scene(str(p.get("scene", "")))
	if root == null:
		return {"error": "Cannot open scene. Supply a project .tscn path."}
	if method == "scene_tree":
		var info := _info(root, root)
		info["scene"] = root.scene_file_path
		return info
	if method == "signals":
		var node := _node(root, str(p.get("node", "")))
		return _signals(node) if node else {"error": "Node no longer exists"}
	if RenderingServer.get_current_rendering_driver_name() == "dummy":
		return {"error": "Scene saving requires a graphical renderer to preserve shader parameters."}
	if root.scene_file_path in p.get("modified", []):
		return {"error": "Save the modified Neovim buffer first: " + root.scene_file_path}
	var conflict := _disk_conflict(root)
	if conflict != "":
		return {"error": conflict}
	match method:
		"add_node":
			return _add(root, p)
		"attach_script":
			return _attach(root, p)
		"connect_signal":
			return _connect(root, p)
		"undo":
			return _undo(root, p.get("modified", []))
	return {"error": "Unknown scene action"}
