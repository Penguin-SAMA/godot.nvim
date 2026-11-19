@tool
extends EditorPlugin

const Actions = preload("res://addons/nvim_bridge/scene_actions.gd")
const BASE = "res://base.tscn"
const TARGET = "Left/Target"
var actions: RefCounted
var failures := 0

func _ready() -> void:
	_run.call_deferred()

func check(ok: bool, label: String, detail: Variant = "") -> void:
	if not ok:
		failures += 1
		printerr("FAIL: ", label, " ", detail)

func request(method: String, params: Dictionary, scene := BASE) -> Dictionary:
	params.scene = scene
	return await actions.dispatch(method, params)

func reject(method: String, params: Dictionary, reason: String, scene := BASE) -> void:
	var before := FileAccess.get_sha256(scene)
	var tree := await request("scene_tree", {}, scene)
	var result := await request(method, params, scene)
	check(str(result.get("error", "")).contains(reason), method + " rejects " + reason, result)
	check(before == FileAccess.get_sha256(scene), "rejection preserves file")
	check(tree == await request("scene_tree", {}, scene), "rejection preserves hierarchy")

func packed_node(scene: String, path: String) -> Node:
	var packed := ResourceLoader.load(scene, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	var root := packed.instantiate()
	var node := root.get_node_or_null(path)
	if node == null:
		root.free()
	return node

func _run() -> void:
	# Let the editor finish importing before executing the suite and exiting.
	for frame in 300:
		await get_tree().process_frame
		if not EditorInterface.get_resource_filesystem().is_scanning():
			break
	actions = Actions.new(self)
	var ops := {"rename_node": {"node": TARGET, "name": "Renamed"}, "delete_node": {"node": TARGET}, "reparent_node": {"node": TARGET, "parent": "Right"}}
	if "--red" in OS.get_cmdline_user_args():
		for method: String in ops:
			var result := await request(method, ops[method])
			print(method, ": ", result)
			check(not result.has("error"), method + " should succeed", result)
		get_tree().quit(1 if failures else 0)
		return
	check(RenderingServer.get_current_rendering_driver_name() != "dummy", "graphical renderer required")
	await request("scene_tree", {})
	var root := EditorInterface.get_edited_scene_root()
	var target := root.get_node(TARGET) as Node2D
	var initial := target.transform
	var global_before := target.global_transform
	var index := target.get_index()
	for method: String in ops:
		var result := await request(method, ops[method])
		check(not result.has("error"), method + " succeeds", result)
		if result.has("error"):
			continue
		var path: String = {"rename_node": "Left/Renamed", "delete_node": TARGET, "reparent_node": "Right/Target"}[method]
		var saved := packed_node(BASE, path)
		check((saved == null) == (method == "delete_node"), method + " persists")
		if saved:
			check(saved.owner != null and saved.get_node("Child").owner == saved.owner, method + " persists owners")
			if method == "reparent_node":
				check(saved.get_index() == 1, "moved node appended")
			saved.owner.free()
		if method == "reparent_node":
			check(target.global_transform.is_equal_approx(global_before), "Node2D global transform")
		var undo := await request("undo", {})
		check(undo.get("undone", false), "undo " + method, undo)
		check(target.owner == root and target.get_node("Child").owner == root, "undo owners")
		var restored := packed_node(BASE, TARGET) as Node2D
		check(restored != null and restored.get_index() == index and restored.transform.is_equal_approx(initial), "undo persists index and local transform")
		if restored:
			restored.owner.free()
	var target3 := root.get_node("Left3/Target3") as Node3D
	var local3 := target3.transform
	var global3 := target3.global_transform
	var moved3 := await request("reparent_node", {"node": "Left3/Target3", "parent": "Right3"})
	check(not moved3.has("error") and target3.global_transform.is_equal_approx(global3), "Node3D global transform", moved3)
	if not moved3.has("error"):
		var undo3 := await request("undo", {})
		check(undo3.get("undone", false) and target3.transform.is_equal_approx(local3), "Node3D undo local transform", undo3)
	await reject("rename_node", {"node": TARGET, "name": "  "}, "Invalid")
	await reject("rename_node", {"node": TARGET, "name": "bad/name"}, "Invalid")
	await reject("rename_node", {"node": TARGET, "name": "Sibling"}, "already")
	await reject("delete_node", {"node": "."}, "root")
	await reject("delete_node", {"node": "Missing"}, "exists")
	await reject("reparent_node", {"node": TARGET, "parent": TARGET + "/Child"}, "cycle")
	await reject("reparent_node", {"node": TARGET, "parent": "Left"}, "current parent")
	await reject("reparent_node", {"node": TARGET, "parent": "Branch"}, "instance")
	await reject("delete_node", {"node": "Branch"}, "instance")
	await reject("delete_node", {"node": TARGET}, "inherited", "res://inherited.tscn")
	await reject("delete_node", {"node": "Target"}, "reference", "res://references.tscn")
	await request("scene_tree", {})
	var left := root.get_node("Left")
	left.set_meta("nested_reference", [{"target": target}])
	await reject("delete_node", {"node": TARGET}, "serialized reference")
	left.remove_meta("nested_reference")
	var callback := Callable(target, "hide")
	check(left.connect("visibility_changed", callback, CONNECT_PERSIST) == OK, "fixture connects signal")
	await reject("rename_node", {"node": TARGET, "name": "Renamed"}, "signal reference")
	left.disconnect("visibility_changed", callback)
	var player := AnimationPlayer.new()
	root.add_child(player)
	player.owner = root
	var library := AnimationLibrary.new()
	var animation := Animation.new()
	var track := animation.add_track(Animation.TYPE_VALUE)
	animation.track_set_path(track, NodePath("Left/Target:position"))
	library.add_animation("test", animation)
	player.add_animation_library("", library)
	await reject("reparent_node", {"node": TARGET, "parent": "Right"}, "animation track reference")
	player.free()
	await reject("delete_node", {"node": TARGET, "modified": [BASE]}, "modified Neovim")
	var original := FileAccess.get_file_as_string(BASE)
	var file := FileAccess.open(BASE, FileAccess.WRITE)
	file.store_string(original + "\n; external change\n")
	file.close()
	await reject("delete_node", {"node": TARGET}, "changed on disk")
	print("Scene structure fixture failures: ", failures)
	get_tree().quit(1 if failures else 0)
