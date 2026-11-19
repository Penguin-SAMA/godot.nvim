@tool
extends EditorDebuggerPlugin

const ACTIONS := ["main", "pause", "stop", "current", "custom"]
var buttons := {}


func _bind() -> bool:
	if is_instance_valid(buttons.get("main")):
		return true
	var base := EditorInterface.get_base_control()
	for candidate in base.find_children("*", "Button", true, false):
		if candidate.theme_type_variation != &"RunBarButton" or candidate.icon != base.get_theme_icon("Pause", "EditorIcons"):
			continue
		var controls := []
		for child in candidate.get_parent().get_children():
			if child is Button and child.theme_type_variation == &"RunBarButton":
				controls.append(child)
		if controls.size() == ACTIONS.size() and controls[1] == candidate and controls[2].icon == base.get_theme_icon("Stop", "EditorIcons"):
			for i in ACTIONS.size():
				buttons[ACTIONS[i]] = controls[i]
			return true
	return false


func state() -> Dictionary:
	if not _bind():
		return {}
	var mode := ""
	var reload := EditorInterface.get_base_control().get_theme_icon("Reload", "EditorIcons")
	for action in ["main", "current", "custom"]:
		if buttons[action].icon == reload:
			mode = action
	return {"mode": mode, "can_pause": not buttons.pause.disabled, "paused": buttons.pause.button_pressed,
		"can_stop": not buttons.stop.disabled}


func _stop_before_launch() -> bool:
	EditorInterface.stop_playing_scene()
	var tree := EditorInterface.get_base_control().get_tree()
	# Let the old debugger disconnect before the new game takes its place.
	# A late disconnect can otherwise stop the newly launched game on Windows.
	var deadline := Time.get_ticks_msec() + 5000
	while Time.get_ticks_msec() < deadline:
		await tree.process_frame
		var active: bool = EditorInterface.is_playing_scene() or not buttons.pause.disabled
		for session in get_sessions():
			active = active or session.is_active()
		if not active:
			await tree.process_frame
			return true
	return false


func dispatch(action: String, scene: String) -> Dictionary:
	if action not in ACTIONS or not _bind():
		return {"error": "The Godot editor run controls are unavailable."}
	var button: Button = buttons[action]
	if button.disabled:
		return {"error": "This run control is currently disabled in Godot."}
	var editor := EditorInterface.get_base_control()
	var window := editor.get_window()
	if window.get_last_exclusive_window() != window:
		return {"error": "Close the open Godot dialog before using the run controls."}
	if action == "pause":
		button.button_pressed = not button.button_pressed
		button.pressed.emit()
		return state()
	if action == "stop":
		EditorInterface.stop_playing_scene()
		return state()
	var mode: String = state().get("mode", "")
	var previous_scene := EditorInterface.get_playing_scene()
	if action == "current" and mode == "current":
		scene = previous_scene
	if action == "current" and not scene.is_empty():
		if not preload("scene_actions.gd").valid_resource(scene) or scene.get_extension().to_lower() not in ["tscn", "scn"] or not ResourceLoader.exists(scene, "PackedScene"):
			return {"error": "Cannot run scene: " + scene}
		var edited := EditorInterface.get_edited_scene_root()
		if edited == null or edited.scene_file_path != scene:
			EditorInterface.open_scene_from_path(scene)
			for frame in 60:
				await editor.get_tree().process_frame
				edited = EditorInterface.get_edited_scene_root()
				if edited != null and edited.scene_file_path == scene:
					break
			if edited == null or edited.scene_file_path != scene:
				return {"error": "Godot could not open " + scene}
	if button is MenuButton:
		window.grab_focus()
		button.show_popup()
		return state()
	if (EditorInterface.is_playing_scene() or not buttons.pause.disabled) and not await _stop_before_launch():
		return {"error": "Godot is still stopping the previous game."}
	match action:
		"main":
			EditorInterface.play_main_scene()
		"current":
			EditorInterface.play_current_scene()
		"custom":
			if mode == "custom" and not previous_scene.is_empty():
				EditorInterface.play_custom_scene(previous_scene)
			else:
				window.grab_focus()
				button.pressed.emit() # Open Godot's scene chooser.
	return state()
